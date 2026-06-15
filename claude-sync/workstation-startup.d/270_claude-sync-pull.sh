#!/bin/bash
# claude-sync plugin — one-shot boot pull.
#
# Pulls every workstation's namespace under gs://${BUCKET}/claude-sync/workstations/
# and merges into /home/user/.claude/. Idempotent. Bails fast when the
# plugin is disabled or the bucket env var is missing.
#
# All claude-sync data lives under the claude-sync/ prefix inside the
# bucket so other plugins can share the same bucket without collisions.
#
# Merge model (see SPEC.md "ADR 2026-06-07"):
#   * projects/, todos/, plans/, session-env/ — namespace-scoped, UUID-
#     named. Staged into a tmpdir, then copied into the live tree with
#     `cp -an` so newer local files win over the GCS copy.
#   * history.jsonl — an append-only union log; each namespace holds a
#     partial view. UNION-MERGED: local + every namespace, torn lines
#     dropped, deduped, sorted by timestamp. Never overwritten wholesale
#     (that was the session-loss bug).
#   * .claude.json — local file is authoritative for machine-local state
#     (auth, onboarding, counters); only per-project `history` arrays are
#     unioned in from other namespaces. Foreign config is never imported.
set -euo pipefail

# --- Detach so the boot pull never blocks workstation startup ----------------
# The cross-namespace pull can move hundreds of MB across dozens of GCS
# namespaces and take many minutes. Run inline, it blocks the
# /etc/workstation-startup.d/ sequence long enough that Cloud Workstations
# tears the container down mid-boot — sshd never stabilizes and `ra connect`
# fails with "the workstation does not have a server running on port 22".
# Re-exec ourselves once, detached into a new session via `setsid --fork`
# (same pattern as the push daemon in 271_*.sh), and return immediately so
# boot completes; the pull then runs to completion in the background.
# RA_CLAUDE_SYNC_PULL_DETACHED guards against infinite re-exec.
if [ "${RA_CLAUDE_SYNC_PULL_DETACHED:-0}" != "1" ]; then
    export RA_CLAUDE_SYNC_PULL_DETACHED=1
    setsid --fork "$0" </dev/null >/dev/null 2>&1
    exit 0
fi

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
LOG_FILE="/var/log/ra-claude-sync.log"
# Last-known-good workstation id, cached on the persistent home disk so a
# transient metadata blip can't flip our identity. See resolve_ws_id.
WS_ID_CACHE="${USER_HOME}/.ra-claude-sync/ws-id"

# Tee both stdout and stderr through to the shared log file so a sync
# regression leaves an auditable trail beyond the boot journal.
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[claude-sync-pull] $(date -u +%H:%M:%S) $*"; }

# Resolve this workstation's stable id. Metadata is authoritative; we
# cache the last-known-good value and prefer it over the `hostname`
# fallback so a momentary metadata outage cannot fork our namespace
# (the metadata name and `hostname` differ on Cloud Workstations:
# "workstations-<uuid>" vs e.g. "personal"). Identical logic lives in the
# push loop heredoc in 271_*.sh — keep the two in sync.
# Returns 0 if resolved from metadata/cache, 1 if it had to use hostname.
resolve_ws_id() {
    local id="" i
    for i in 1 2 3; do
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

# Union-merge JSONL files into a destination, in place.
#   $1 = destination path ; $2.. = extra source files to fold in.
# Tolerates torn/invalid lines (fromjson? // empty), drops only exact
# duplicate objects (`unique` — never drops a record that merely shares a
# timestamp/sessionId with another), sorts by timestamp. The temp file is
# created in the destination's own directory so the write-back is a true
# atomic rename (mv across filesystems would be a non-atomic copy). Never
# replaces the destination with an empty result (guards a jq failure from
# wiping history).
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
    return 0
}

# Merge .claude.json: keep the local file as the authoritative base and
# union in only per-project `history` arrays from remote namespaces.
#   $1 = local .claude.json (base) ; $2.. = remote claude.json files.
# Skips any source (including the base) that is not valid JSON. Atomic,
# validated write-back.
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
    return 0
}

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0
if [ -z "${RA_PLUGIN_CLAUDE_SYNC_BUCKET:-}" ]; then
    log "RA_PLUGIN_CLAUDE_SYNC_BUCKET unset; skipping"
    exit 0
fi

BUCKET="${RA_PLUGIN_CLAUDE_SYNC_BUCKET}"

WS_ID="$(resolve_ws_id)" || log "WARN: metadata + cache both unavailable; using hostname=${WS_ID} (namespace may fork)"
PLUGIN_PREFIX="gs://${BUCKET}/claude-sync"

log "starting pull as ws-id=${WS_ID} from ${PLUGIN_PREFIX}"

mkdir -p "${USER_HOME}/.claude"

# List namespaces. `gcloud storage ls` returns one
# `gs://bucket/claude-sync/workstations/<ws>/` per line; an
# empty/nonexistent prefix is not an error here.
mapfile -t NAMESPACES < <(gcloud storage ls "${PLUGIN_PREFIX}/workstations/" 2>>"${LOG_FILE}" | sort -u || true)

if [ "${#NAMESPACES[@]}" -eq 0 ]; then
    log "no namespaces under ${PLUGIN_PREFIX}/workstations/ — first boot"
    chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.claude"
    exit 0
fi

# Stage everything into a tmpdir so the existing live tree is unaffected
# until we cp-no-clobber / merge on top.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/history" "${STAGE}/claudejson"

for ns in "${NAMESPACES[@]}"; do
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    [ -z "${ns_id}" ] && continue
    [ "${ns_id}" = "${WS_ID}" ] && continue
    log "staging namespace ${ns_id}"
    for sub in projects todos plans session-env; do
        mkdir -p "${STAGE}/${sub}"
        gcloud storage rsync --recursive \
            "${ns}${sub}/" "${STAGE}/${sub}/" 2>>"${LOG_FILE}" || true
    done
    # Single-file, merge-on-read members: stage one copy per namespace so
    # the union merge below can fold them all in.
    gcloud storage cp "${ns}history.jsonl" "${STAGE}/history/${ns_id}.jsonl" 2>>"${LOG_FILE}" || true
    gcloud storage cp "${ns}claude.json"   "${STAGE}/claudejson/${ns_id}.json" 2>>"${LOG_FILE}" || true
done

# Merge staged directory content into ~/.claude using `cp -an` (archive +
# no-clobber) so any newer local file wins. First-time fetches still
# populate empty subtrees.
for sub in projects todos plans session-env; do
    [ -d "${STAGE}/${sub}" ] || continue
    mkdir -p "${USER_HOME}/.claude/${sub}"
    cp -an "${STAGE}/${sub}/." "${USER_HOME}/.claude/${sub}/" 2>>"${LOG_FILE}" || true
done

# Union-merge the append-only / shared single files.
log "union-merging history.jsonl across $(ls -1 "${STAGE}/history" 2>/dev/null | wc -l) namespace(s) + local"
merge_jsonl_history "${USER_HOME}/.claude/history.jsonl" "${STAGE}"/history/*.jsonl

log "merging .claude.json project history across $(ls -1 "${STAGE}/claudejson" 2>/dev/null | wc -l) namespace(s)"
merge_claude_json "${USER_HOME}/.claude.json" "${STAGE}"/claudejson/*.json

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.claude"
[ -f "${USER_HOME}/.claude.json" ] && chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.claude.json"
[ -f "${WS_ID_CACHE}" ] && chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${WS_ID_CACHE}")" 2>/dev/null || true
log "done"
