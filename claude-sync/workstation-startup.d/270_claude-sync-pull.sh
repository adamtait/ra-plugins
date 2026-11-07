#!/bin/bash
# claude-sync plugin — install the shared helpers + pull script, then run
# the boot pull detached.
#
# Materializes two files (both overwritten on every boot, so a plugin
# upgrade takes effect on the next `ra create`):
#
#   /usr/local/lib/ra-claude-sync/common.sh  — helpers shared by the pull
#       script and the push loop (271_*.sh): namespace resolution, the
#       history/.claude.json union merges, and the per-file tree merge.
#       Replaces the old "keep this identical to 271_*.sh" duplication.
#   /usr/local/bin/ra-claude-sync-pull.sh    — merges other workstations'
#       namespaces into /home/user/.claude/. Run here with --boot, and
#       periodically by the push loop (pull_interval_seconds).
#
# Namespace model (see docs/adr/0006-per-workstation-namespace.md): every
# workstation pushes ONLY to its own namespace, `<stable-id>--<hostname>`.
# The stable id alone is per-*config* (Cloud Workstations sets container env
# on the config), so two workstations from one config used to share — and
# overwrite — a single namespace.
#
# Merge model (see docs/adr/0002-merge-based-sync.md + ADR 0006):
#   * projects/, todos/, plans/, session-env/ — per file: copy if missing
#     locally; fast-forward if the remote copy strictly extends the local
#     one and the local file is idle; otherwise keep local (never clobber).
#   * history.jsonl — union-merged, written back only if the local file did
#     not change while the merge ran.
#   * .claude.json — boot pull only: local base + per-project history union.
#
# Runs as root (workstation SA auth via the metadata server).
set -euo pipefail

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0

LIB_DIR="/usr/local/lib/ra-claude-sync"
COMMON_PATH="${LIB_DIR}/common.sh"
PULL_PATH="/usr/local/bin/ra-claude-sync-pull.sh"

mkdir -p "${LIB_DIR}"

cat > "${COMMON_PATH}" <<'COMMON_EOF'
# shellcheck shell=bash
# ra claude-sync shared helpers — installed by 270_claude-sync-pull.sh.
# Sourced by ra-claude-sync-pull.sh and ra-claude-sync-loop.sh. Set
# LOG_TAG before sourcing to label log lines.
#
# Paths are overridable via RA_CLAUDE_SYNC_* env vars so the merge logic
# can be exercised against scratch trees without touching a real home.

USER_NAME="${RA_CLAUDE_SYNC_USER_NAME:-user}"
USER_HOME="${RA_CLAUDE_SYNC_USER_HOME:-/home/${USER_NAME}}"
LOG_FILE="${RA_CLAUDE_SYNC_LOG_FILE:-/var/log/ra-claude-sync.log}"
# Persistent per-workstation state on the home disk (Cloud Workstations
# only persist /home). Outside ~/.claude and off the push allowlist.
STATE_DIR="${USER_HOME}/.ra-claude-sync"
WS_ID_CACHE="${STATE_DIR}/ws-id"
WS_SUFFIX_FILE="${STATE_DIR}/ws-suffix"
# A local file modified this recently may be open in a live Claude Code
# session; the tree merge never fast-forwards it.
ACTIVE_WINDOW_SECONDS="${RA_CLAUDE_SYNC_ACTIVE_WINDOW_SECONDS:-120}"

log() { echo "[${LOG_TAG:-claude-sync}] $(date -u +%H:%M:%S) $*"; }

# GCE instance name ("workstations-<uuid>"; fresh on every `ra create`).
# Empty when the metadata server is unreachable.
instance_name() {
    curl -fs -m 5 -H 'Metadata-Flavor: Google' \
        'http://metadata.google.internal/computeMetadata/v1/instance/name' \
        2>/dev/null || true
}

# Legacy identity, used only when RA_PLUGIN_CLAUDE_SYNC_NAMESPACE is unset:
# metadata (authoritative) → last-known-good cache → hostname. Only
# metadata results are cached, so a metadata blip cannot fork the
# namespace permanently. Returns 1 if it had to fall back to hostname.
resolve_ws_id() {
    local id="" i
    for i in 1 2 3; do
        id="$(instance_name)"
        [ -n "${id}" ] && break
        sleep 1
    done
    if [ -n "${id}" ]; then
        mkdir -p "${STATE_DIR}" 2>/dev/null || true
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

# Lowercase and collapse anything outside [a-z0-9_-] to '-', trimming
# leading/trailing separators — the same rule ra core's idSafeRe applies.
sanitize_id() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/[-_]+$//'
}

# Per-workstation suffix: the hostname, which on Cloud Workstations is the
# workstation name (unique within a config, kept across restarts). If the
# hostname is unusable, fall back to a random id persisted on the home disk.
host_suffix() {
    local h s
    h="$(sanitize_id "$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)")"
    case "${h}" in
        ""|localhost|localhost-localdomain) ;;
        *) printf '%s' "${h}"; return 0 ;;
    esac
    if [ -r "${WS_SUFFIX_FILE}" ]; then
        s="$(head -n1 "${WS_SUFFIX_FILE}" 2>/dev/null || true)"
        if [ -n "${s}" ]; then printf '%s' "${s}"; return 0; fi
    fi
    s="ws-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    printf '%s\n' "${s}" > "${WS_SUFFIX_FILE}" 2>/dev/null || true
    printf '%s' "${s}"
}

# Sets WS_ID to this workstation's namespace. With the ra-core stable id:
# `<stable-id>--<hostname>`. The stable id never contains "--" (core
# collapses separator runs), so the double hyphen is an unambiguous join.
resolve_namespace() {
    if [ -n "${RA_PLUGIN_CLAUDE_SYNC_NAMESPACE:-}" ]; then
        WS_ID="${RA_PLUGIN_CLAUDE_SYNC_NAMESPACE}--$(host_suffix)"
        log "using namespace ${WS_ID} (stable id + workstation hostname)"
    elif WS_ID="$(resolve_ws_id)"; then
        log "using namespace ${WS_ID} (instance id; RA_PLUGIN_CLAUDE_SYNC_NAMESPACE unset)"
    else
        log "WARN: metadata + cache both unavailable; using hostname=${WS_ID} (namespace may fork)"
    fi
}

# Change-detection signature: size, inode, and nanosecond mtime.
file_sig() { stat -c '%s:%i:%y' -- "$1" 2>/dev/null || echo absent; }

# Atomically replace $1 with $2 only if $1 still matches signature $3.
# The temp file inherits the destination's owner/mode first, so a file
# Claude Code is about to append to never becomes root-owned. Returns 1
# (and removes the temp file) if the destination changed underneath us.
replace_if_unchanged() {
    local dest="$1" tmp="$2" sig="$3"
    if [ -e "${dest}" ]; then
        chown --reference="${dest}" "${tmp}" 2>/dev/null || true
        chmod --reference="${dest}" "${tmp}" 2>/dev/null || true
    fi
    if [ "$(file_sig "${dest}")" != "${sig}" ]; then
        rm -f "${tmp}"
        return 1
    fi
    mv -f "${tmp}" "${dest}"
}

# Union-merge JSONL files into $1, in place; $2.. are extra sources.
# Drops torn/invalid lines, dedups exact objects, sorts by timestamp.
# The temp file lives beside the destination so the write-back is an
# atomic rename; an empty result never replaces the destination; and the
# write-back is retried if Claude Code appended to $1 mid-merge, so a
# periodic pull can never eat a freshly-written prompt.
merge_jsonl_history() {
    local dest="$1"; shift
    local f attempt sig tmp
    local -a srcs=()
    for f in "$@"; do [ -f "${f}" ] && srcs+=("${f}"); done
    [ "${#srcs[@]}" -gt 0 ] || return 0
    mkdir -p "$(dirname "${dest}")"
    for attempt in 1 2 3; do
        sig="$(file_sig "${dest}")"
        local -a files=("${srcs[@]}")
        [ -f "${dest}" ] && files=("${dest}" "${srcs[@]}")
        tmp="$(mktemp "${dest}.merge.XXXXXX")"
        if ! cat "${files[@]}" 2>>"${LOG_FILE}" \
            | jq -R -c 'fromjson? // empty | select(type=="object")' 2>>"${LOG_FILE}" \
            | jq -s -c 'unique | sort_by(.timestamp // 0) | .[]' 2>>"${LOG_FILE}" > "${tmp}" \
            || [ ! -s "${tmp}" ]; then
            rm -f "${tmp}"
            return 0
        fi
        if replace_if_unchanged "${dest}" "${tmp}" "${sig}"; then
            return 0
        fi
        log "history.jsonl changed during merge; retrying (${attempt}/3)"
    done
    log "WARN: history.jsonl kept changing; merge skipped this pass"
    return 0
}

# Merge .claude.json: local file is the authoritative base; only
# per-project `history` arrays are unioned in from $2.. Invalid JSON
# sources are skipped. Written back only if the base did not change
# while merging (Claude Code rewrites this file frequently).
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
    local sig tmp
    sig="$(file_sig "${base}")"
    tmp="$(mktemp "${base}.merge.XXXXXX")"
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
    ' "${base}" "${rfiles[@]}" > "${tmp}" 2>>"${LOG_FILE}" \
        && [ -s "${tmp}" ] && jq -e . "${tmp}" >/dev/null 2>&1; then
        replace_if_unchanged "${base}" "${tmp}" "${sig}" \
            || log ".claude.json changed during merge; skipped this pass"
        return 0
    fi
    rm -f "${tmp}"
    return 0
}

# Merge one staged tree ($1, a namespace's mirror of e.g. projects/) into
# the live tree ($2), file by file:
#   * missing locally            → copy in
#   * remote strictly extends the local file (local is a byte prefix of
#     remote) and the local file is idle → fast-forward (atomic replace)
#   * remote larger but diverged → keep local, logged
#   * equal or smaller remote    → keep local silently (normal: local ahead)
# Never deletes and never overwrites a diverged or active local file.
#
# Sizes for both trees come from one `find -printf` each, so the common
# case (nothing changed) costs no per-file process spawns — a history of
# thousands of transcripts is re-merged every pull_interval_seconds.
merge_tree() {
    local src="$1" dest="$2"
    [ -d "${src}" ] || return 0
    mkdir -p "${dest}"
    local now rec f rel d rsize lsize mtime sig tmp
    local copied=0 forwarded=0 kept=0
    local -A local_size=()
    now="$(date +%s)"
    while IFS= read -r -d '' rec; do
        local_size["${rec#* }"]="${rec%% *}"
    done < <(find "${dest}" -type f -printf '%s %P\0')
    while IFS= read -r -d '' rec; do
        rsize="${rec%% *}"
        rel="${rec#* }"
        f="${src}/${rel}"
        d="${dest}/${rel}"
        lsize="${local_size["${rel}"]-}"
        if [ -z "${lsize}" ]; then
            # Missing locally (or present but not a regular file, which
            # the bulk no-clobber copy below leaves alone).
            [ -e "${d}" ] || copied=$((copied + 1))
            continue
        fi
        [ "${rsize}" -gt "${lsize}" ] || continue
        mtime="$(stat -c %Y -- "${d}")"
        if [ $((now - mtime)) -lt "${ACTIVE_WINDOW_SECONDS}" ]; then
            log "skip-active ${rel}: modified locally $((now - mtime))s ago"
            kept=$((kept + 1))
            continue
        fi
        sig="$(file_sig "${d}")"
        if cmp -s -n "${lsize}" -- "${d}" "${f}"; then
            tmp="${d}.ra-sync.$$"
            if cp -- "${f}" "${tmp}" 2>>"${LOG_FILE}" \
                && replace_if_unchanged "${d}" "${tmp}" "${sig}"; then
                log "fast-forward ${rel} (${lsize} -> ${rsize} bytes)"
                forwarded=$((forwarded + 1))
            else
                rm -f "${tmp}"
                log "skip ${rel}: changed locally during fast-forward"
                kept=$((kept + 1))
            fi
        else
            log "keep-local ${rel}: diverged from remote (local=${lsize} remote=${rsize} bytes)"
            kept=$((kept + 1))
        fi
    done < <(find "${src}" -type f -printf '%s %P\0')
    # Copy every missing file in one no-clobber pass (new files are
    # UUID-named, so nothing local is racing to create them). Ownership is
    # fixed by the pull's final chown.
    if [ "${copied}" -gt 0 ]; then
        cp -rn --preserve=mode,timestamps -- "${src}/." "${dest}/" 2>>"${LOG_FILE}" || true
    fi
    log "merged ${src}: ${copied} new, ${forwarded} fast-forwarded, ${kept} kept local"
}
COMMON_EOF
chmod 0644 "${COMMON_PATH}"

cat > "${PULL_PATH}" <<'PULL_EOF'
#!/bin/bash
# ra-claude-sync pull — installed by 270_claude-sync-pull.sh.
#
# Merges other workstations' namespaces from
# gs://${BUCKET}/claude-sync/workstations/ into /home/user/.claude/.
#
#   ra-claude-sync-pull.sh --boot   boot pull (270_*.sh): also merges our
#                                   OWN namespace (restores history after a
#                                   rebuild under the same name) and
#                                   .claude.json; logs to the log file.
#   ra-claude-sync-pull.sh          periodic pull (push loop): other
#                                   namespaces + history.jsonl only;
#                                   output goes to the caller's stdout.
#
# Namespaces are mirrored incrementally into /var/cache/ra-claude-sync/
# (ephemeral — the first pull after a restart is a full download), then
# merged per file by merge_tree (common.sh). A lock keeps the boot pull and
# a periodic pull from overlapping.
set -euo pipefail

LOG_TAG="claude-sync-pull"
# shellcheck source=/dev/null
. "${RA_CLAUDE_SYNC_COMMON:-/usr/local/lib/ra-claude-sync/common.sh}"

BOOT=0
[ "${1:-}" = "--boot" ] && BOOT=1

if [ "${BOOT}" -eq 1 ]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    exec >> "${LOG_FILE}" 2>&1
fi

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0
if [ -z "${RA_PLUGIN_CLAUDE_SYNC_BUCKET:-}" ]; then
    log "RA_PLUGIN_CLAUDE_SYNC_BUCKET unset; skipping"
    exit 0
fi

CACHE_DIR="${RA_CLAUDE_SYNC_CACHE_DIR:-/var/cache/ra-claude-sync}"
MIRROR_DIR="${CACHE_DIR}/mirror"
MANIFEST_DIR="${CACHE_DIR}/manifest"
LOCK_FILE="${RA_CLAUDE_SYNC_PULL_LOCK:-/run/ra-claude-sync.pull.lock}"
mkdir -p "${MIRROR_DIR}" "${MANIFEST_DIR}" "$(dirname "${LOCK_FILE}")"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "another pull is already running; skipping this one"
    exit 0
fi

BUCKET="${RA_PLUGIN_CLAUDE_SYNC_BUCKET}"
PLUGIN_PREFIX="gs://${BUCKET}/claude-sync"
resolve_namespace

# Recency/age filter (ADR 0004 #1): rank other namespaces by manifest
# last_push_at_epoch; keep those newer than MAX_AGE_DAYS and within the
# MAX_NAMESPACES most recent.
MAX_AGE_DAYS="${RA_PLUGIN_CLAUDE_SYNC_PULL_MAX_AGE_DAYS:-30}"
MAX_NAMESPACES="${RA_PLUGIN_CLAUDE_SYNC_PULL_MAX_NAMESPACES:-15}"
case "${MAX_AGE_DAYS}" in *[!0-9]*|"") MAX_AGE_DAYS=30 ;; esac
case "${MAX_NAMESPACES}" in *[!0-9]*|"") MAX_NAMESPACES=15 ;; esac

mode="periodic"; [ "${BOOT}" -eq 1 ] && mode="boot"
log "starting ${mode} pull as ws-id=${WS_ID} from ${PLUGIN_PREFIX} (max_age_days=${MAX_AGE_DAYS} max_namespaces=${MAX_NAMESPACES})"

mkdir -p "${USER_HOME}/.claude"

mapfile -t NAMESPACES < <(gcloud storage ls "${PLUGIN_PREFIX}/workstations/" 2>>"${LOG_FILE}" | sort -u || true)
if [ "${#NAMESPACES[@]}" -eq 0 ]; then
    log "no namespaces under ${PLUGIN_PREFIX}/workstations/ — first boot"
    exit 0
fi

now_epoch="$(date -u +%s)"
if [ "${MAX_AGE_DAYS}" -gt 0 ]; then
    cutoff_epoch=$(( now_epoch - MAX_AGE_DAYS * 86400 ))
else
    cutoff_epoch=0
fi

# All manifests in one gcloud round-trip, mirrored incrementally. A
# missing/unreadable manifest ranks as epoch 0 (oldest).
gcloud storage rsync --recursive \
    "${PLUGIN_PREFIX}/_manifest/" "${MANIFEST_DIR}/" 2>>"${LOG_FILE}" || true

PULL_NS=()
ranked_rows=""
for ns in "${NAMESPACES[@]}"; do
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    [ -z "${ns_id}" ] && continue
    if [ "${ns_id}" = "${WS_ID}" ]; then
        # Our own namespace is merged only at boot (to restore a rebuilt
        # workstation's history). Periodically it holds nothing we don't
        # already have locally, and re-mirroring it would re-download every
        # file we just pushed.
        if [ "${BOOT}" -eq 1 ]; then
            log "include ${ns_id}: own namespace (boot restore)"
            PULL_NS+=("${ns}")
        fi
        continue
    fi
    ts="$(jq -r '.last_push_at_epoch // 0' "${MANIFEST_DIR}/${ns_id}.json" 2>/dev/null || echo 0)"
    ts="${ts:-0}"
    case "${ts}" in *[!0-9]*) ts=0 ;; esac
    ranked_rows+="${ts}	${ns}"$'\n'
done

mapfile -t ranked_sorted < <(printf '%s' "${ranked_rows}" | sort -rn -k1,1 | sed '/^$/d')

kept=0
for row in "${ranked_sorted[@]}"; do
    ts="${row%%	*}"
    ns="${row#*	}"
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    if [ "${cutoff_epoch}" -gt 0 ] && [ "${ts}" -lt "${cutoff_epoch}" ]; then
        if [ "${BOOT}" -eq 1 ]; then
            if [ "${ts}" -eq 0 ]; then
                log "skip ${ns_id}: no/invalid manifest (treated as oldest, beyond ${MAX_AGE_DAYS}d TTL)"
            else
                log "skip ${ns_id}: last_push_at_epoch=${ts} older than ${MAX_AGE_DAYS}d TTL (cutoff=${cutoff_epoch})"
            fi
        fi
        continue
    fi
    if [ "${kept}" -ge "${MAX_NAMESPACES}" ]; then
        log "skip ${ns_id}: beyond top-${MAX_NAMESPACES} recency cap (last_push_at_epoch=${ts})"
        continue
    fi
    PULL_NS+=("${ns}")
    kept=$((kept + 1))
done

log "selected ${#PULL_NS[@]} of ${#NAMESPACES[@]} namespace(s) for pull"
if [ "${#PULL_NS[@]}" -eq 0 ]; then
    log "no eligible namespaces after age/cap filter — nothing to pull"
    exit 0
fi

# Mirror each selected namespace, then merge it into the live tree.
history_srcs=()
claudejson_srcs=()
for ns in "${PULL_NS[@]}"; do
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    m="${MIRROR_DIR}/${ns_id}"
    mkdir -p "${m}"
    for sub in projects todos plans session-env; do
        mkdir -p "${m}/${sub}"
        gcloud storage rsync --recursive \
            "${ns}${sub}/" "${m}/${sub}/" 2>>"${LOG_FILE}" || true
        merge_tree "${m}/${sub}" "${USER_HOME}/.claude/${sub}"
    done
    # Single-file members: one copy per namespace, folded in below. A
    # failed fetch drops the stale mirror copy rather than re-merging it.
    gcloud storage cp "${ns}history.jsonl" "${m}/history.jsonl" 2>>"${LOG_FILE}" \
        || rm -f "${m}/history.jsonl"
    history_srcs+=("${m}/history.jsonl")
    if [ "${BOOT}" -eq 1 ]; then
        gcloud storage cp "${ns}claude.json" "${m}/claude.json" 2>>"${LOG_FILE}" \
            || rm -f "${m}/claude.json"
        claudejson_srcs+=("${m}/claude.json")
    fi
done

log "union-merging history.jsonl across ${#history_srcs[@]} namespace(s) + local"
merge_jsonl_history "${USER_HOME}/.claude/history.jsonl" "${history_srcs[@]}"

if [ "${BOOT}" -eq 1 ]; then
    log "merging .claude.json project history across ${#claudejson_srcs[@]} namespace(s)"
    merge_claude_json "${USER_HOME}/.claude.json" "${claudejson_srcs[@]}"
fi

# Drop mirrors of namespaces that aged out of the selection so the cache
# tracks the working set. Only at boot: a periodic pull deliberately skips
# our own namespace, and must not throw away its mirror.
if [ "${BOOT}" -eq 1 ]; then
    for d in "${MIRROR_DIR}"/*/; do
        [ -d "${d}" ] || continue
        id="$(basename "${d}")"
        keep=0
        for ns in "${PULL_NS[@]}"; do
            ns_id="${ns%/}"; ns_id="${ns_id##*/}"
            [ "${ns_id}" = "${id}" ] && { keep=1; break; }
        done
        [ "${keep}" -eq 1 ] || rm -rf "${d}"
    done
fi

chown -R "${USER_NAME}:" "${USER_HOME}/.claude" 2>/dev/null || true
[ -f "${USER_HOME}/.claude.json" ] && chown "${USER_NAME}:" "${USER_HOME}/.claude.json" 2>/dev/null || true
[ -d "${STATE_DIR}" ] && chown -R "${USER_NAME}:" "${STATE_DIR}" 2>/dev/null || true
log "done (${mode})"
PULL_EOF
chmod 0755 "${PULL_PATH}"

# Detach the boot pull so it never blocks the workstation-startup.d
# sequence: a multi-GB pull run inline once kept sshd from stabilizing
# and Cloud Workstations tore the container down mid-boot. The pull
# script logs to the log file itself under --boot.
if ! setsid --fork "${PULL_PATH}" --boot </dev/null >/dev/null 2>&1; then
    echo "[claude-sync-pull] WARNING: detached boot pull failed to start;" \
         "boot pull skipped this boot" >&2
fi
exit 0
