#!/bin/bash
# claude-sync plugin — image-build hook.
#
# The runtime scripts need `jq`, `curl`, and `gcloud`. curl and gcloud
# are guaranteed by the Cloud Workstations code-oss base image. jq is
# NOT — it is not part of the default Debian dev image Google ships —
# so we install it explicitly. We only call apt when jq is actually
# missing, avoiding a redundant apt-get update on every build.
#
# Also bakes the shared shell library both runtime scripts source
# (270_*.sh pull and the push loop 271_*.sh installs). Only
# Dockerfile.d/, workstation-startup.d/ and profile.d/ ship into the
# image, so the library travels as a heredoc here instead of as a file.
# RA_CLAUDE_SYNC_LIB_DIR overrides the install dir (tests only).
#
# `systemctl` is only used on images where systemd is PID 1; on Cloud
# Workstations' default image (entrypoint.sh as PID 1) the loop runs
# via setsid instead and systemctl is unused. The probe below is
# therefore informational only.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
    rm -rf /var/lib/apt/lists/*
fi

LIB_DIR="${RA_CLAUDE_SYNC_LIB_DIR:-/usr/local/lib/ra-claude-sync}"
mkdir -p "${LIB_DIR}"
cat > "${LIB_DIR}/lib.sh" <<'LIB_EOF'
# ra-claude-sync shared library — installed by Dockerfile.d/110_claude-sync-tools.sh.
#
# Sourced by /etc/workstation-startup.d/270_claude-sync-pull.sh and
# /usr/local/bin/ra-claude-sync-loop.sh so the merge rules, workstation
# identity and namespace selection cannot drift between pull and push.
# Callers must define LOG_FILE, WS_ID_CACHE and a `log` function first.
# See docs/adr/0002-merge-based-sync.md and 0006-rebuild-restore-and-merge-on-push.md.

# Resolve this workstation's GCE instance name. Metadata is authoritative;
# we cache the last-known-good value and prefer it over the `hostname`
# fallback so a momentary metadata outage cannot fork our namespace
# (the metadata name and `hostname` differ on Cloud Workstations:
# "workstations-<uuid>" vs e.g. "personal").
# Returns 0 if resolved from metadata/cache, 1 if it had to use hostname.
resolve_ws_id() {
    local id=""
    for _ in 1 2 3; do
        id="$(curl -fs -H 'Metadata-Flavor: Google' \
            'http://metadata.google.internal/computeMetadata/v1/instance/name' \
            2>>"${LOG_FILE}" || true)"
        [ -n "${id}" ] && break
        id=""
        sleep 1
    done
    if [ -n "${id}" ]; then
        mkdir -p "$(dirname "${WS_ID_CACHE}")" 2>/dev/null || true
        printf '%s\n' "${id}" > "${WS_ID_CACHE}" 2>/dev/null || true
        printf '%s' "${id}"
        return 0
    fi
    if [ -r "${WS_ID_CACHE}" ]; then
        local cached
        cached="$(head -n1 "${WS_ID_CACHE}" 2>/dev/null || true)"
        if [ -n "${cached}" ]; then
            printf '%s' "${cached}"
            return 0
        fi
    fi
    printf '%s' "$(hostname)"
    return 1
}

# Namespace selection (ADR 0004 #3). Prefer the stable
# RA_PLUGIN_CLAUDE_SYNC_NAMESPACE injected by `ra create` so a rebuilt
# workstation reuses ONE namespace; fall back to resolve_ws_id() when unset.
# Sets WS_ID (namespace) and WRITER_ID (this instance — distinct from WS_ID
# whenever the stable namespace is in use; recorded in the manifest so two
# live workstations sharing a namespace can be detected).
select_namespace() {
    local from_metadata=1
    WRITER_ID="$(resolve_ws_id)" || from_metadata=0
    if [ -n "${RA_PLUGIN_CLAUDE_SYNC_NAMESPACE:-}" ]; then
        WS_ID="${RA_PLUGIN_CLAUDE_SYNC_NAMESPACE}"
        log "using stable namespace from RA_PLUGIN_CLAUDE_SYNC_NAMESPACE=${WS_ID}"
    else
        WS_ID="${WRITER_ID}"
        [ "${from_metadata}" -eq 1 ] || log "WARN: metadata + cache both unavailable; using hostname=${WS_ID} (namespace may fork)"
    fi
}

# Union-merge JSONL files into a destination, in place.
#   $1 = destination path ; $2.. = extra source files to fold in.
# Tolerates torn/invalid lines (fromjson? // empty), drops only exact
# duplicate objects (`unique` — never drops a record that merely shares a
# timestamp/sessionId with another), sorts by timestamp. The temp file is
# created in the destination's own directory so the write-back is a true
# atomic rename (mv across filesystems would be a non-atomic copy). Never
# replaces the destination with an empty result (guards a jq failure from
# wiping history). Returns 1 when the merge failed or came out empty (the
# destination is then untouched) so the push can refuse to upload an
# unmerged copy; 0 on success or when there was nothing to merge.
merge_jsonl_history() {
    local dest="$1"; shift
    local -a files=()
    [ -f "${dest}" ] && files+=("${dest}")
    local f
    for f in "$@"; do [ -f "${f}" ] && files+=("${f}"); done
    [ "${#files[@]}" -gt 0 ] || return 0
    local tmp; tmp="$(mktemp "${dest}.merge.XXXXXX")"
    if cat "${files[@]}" 2>>"${LOG_FILE}" \
        | jq -R -c 'fromjson? // empty | select(type=="object")' 2>>"${LOG_FILE}" \
        | jq -s -c 'unique | sort_by(.timestamp // 0) | .[]' 2>>"${LOG_FILE}" > "${tmp}"; then
        if [ -s "${tmp}" ]; then
            mv -f "${tmp}" "${dest}"
            return 0
        fi
    fi
    rm -f "${tmp}"
    return 1
}

# Merge .claude.json: keep the local file as the authoritative base and
# union in only per-project `history` arrays from remote copies.
#   $1 = .claude.json (base, rewritten in place) ; $2.. = remote claude.json files.
# Skips any source (including the base) that is not valid JSON. Atomic,
# validated write-back. Returns 1 if the jq merge itself failed (base
# untouched); 0 on success or when no valid remote source exists.
merge_claude_json() {
    local base="$1"; shift
    [ -f "${base}" ] || return 0
    jq -e . "${base}" >/dev/null 2>&1 || { log ".claude.json base invalid; leaving as-is"; return 0; }
    local -a rfiles=()
    local f
    for f in "$@"; do
        [ -f "${f}" ] || continue
        jq -e . "${f}" >/dev/null 2>&1 && rfiles+=("${f}")
    done
    [ "${#rfiles[@]}" -gt 0 ] || return 0
    # Temp in the destination's own directory → atomic rename on write-back.
    local tmp; tmp="$(mktemp "${base}.merge.XXXXXX")"
    if jq -s '
        # order-preserving unique (history entries have no timestamp to sort by)
        def dedup_keep_order: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
        .[0] as $base
        | reduce .[1:][] as $r ($base;
            reduce (($r.projects // {}) | to_entries[]) as $e (.;
                (($e.value.history) // []) as $rh
                | if ($rh | length) > 0
                  then .projects[$e.key].history =
                       (((.projects[$e.key].history // []) + $rh) | dedup_keep_order)
                  else . end
            )
          )
    ' "${base}" "${rfiles[@]}" > "${tmp}" 2>>"${LOG_FILE}"; then
        if [ -s "${tmp}" ] && jq -e . "${tmp}" >/dev/null 2>&1; then
            mv -f "${tmp}" "${base}"
            return 0
        fi
    fi
    rm -f "${tmp}"
    return 1
}

# Read a namespace manifest's writer fields as "<writer>\t<last_push_at_epoch>".
# $1 is a gs:// object or an already-downloaded local file. Prints nothing
# if the manifest is missing or unreadable.
read_manifest_writer() {
    local reader=(cat)
    [[ "$1" == gs://* ]] && reader=(gcloud storage cat)
    "${reader[@]}" "$1" 2>>"${LOG_FILE}" \
        | jq -r '"\(.writer // "")\t\(.last_push_at_epoch // 0)"' 2>>"${LOG_FILE}" || true
}

# Warn when a manifest shows a different instance pushed to this namespace
# recently — two live workstations sharing one namespace (ADR 0006).
#   $1 = manifest (gs:// or local file) ; $2 = freshness window in seconds.
# Returns 0 and logs a WARN if shared, 1 otherwise.
check_shared_writer() {
    local row writer ts now
    row="$(read_manifest_writer "$1")"
    [ -n "${row}" ] || return 1
    writer="${row%%	*}"; ts="${row#*	}"
    case "${ts}" in ''|*[!0-9]*) ts=0 ;; esac
    now="$(date -u +%s)"
    if [ -n "${writer}" ] && [ "${writer}" != "${WRITER_ID}" ] && [ $(( now - ts )) -le "$2" ]; then
        log "WARN: namespace ${WS_ID} shared with live writer ${writer} (last push $(( now - ts ))s ago); this instance is ${WRITER_ID}"
        return 0
    fi
    return 1
}
LIB_EOF
chmod 0644 "${LIB_DIR}/lib.sh"

# Soft assertions — fail at runtime is better than blocking the image build.
command -v curl   >/dev/null 2>&1 || echo "[claude-sync] WARN: curl not in base image" >&2
command -v gcloud >/dev/null 2>&1 || echo "[claude-sync] WARN: gcloud not in base image" >&2
# Informational only: setsid fallback runs without systemctl on the
# default Cloud Workstations image.
command -v systemctl >/dev/null 2>&1 || echo "[claude-sync] INFO: systemctl absent; setsid fallback will be used at boot" >&2
