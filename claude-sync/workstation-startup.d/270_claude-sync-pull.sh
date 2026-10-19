#!/bin/bash
# claude-sync plugin — one-shot boot pull.
#
# Pulls every eligible namespace under gs://${BUCKET}/claude-sync/workstations/
# and merges into /home/user/.claude/. Idempotent. Bails fast when the
# plugin is disabled or the bucket env var is missing.
#
# All claude-sync data lives under the claude-sync/ prefix inside the
# bucket so other plugins can share the same bucket without collisions.
#
# Merge model (see docs/adr/0002-merge-based-sync.md):
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
#
# Our OWN namespace is always merged first, exempt from the age/cap filter
# (docs/adr/0006-rebuild-restore-and-merge-on-push.md): with the stable
# namespace a rebuilt workstation's previous state lives only there.
#
# Progress is published to ${RUN_DIR}/pull.json so the push loop can wait
# for the merge and `claude-sync status` can report it.
#
# The RA_CLAUDE_SYNC_* path overrides below exist for tests/run.sh only.
set -euo pipefail

USER_NAME="user"
USER_HOME="${RA_CLAUDE_SYNC_USER_HOME:-/home/${USER_NAME}}"
LOG_FILE="${RA_CLAUDE_SYNC_LOG_FILE:-/var/log/ra-claude-sync.log}"
RUN_DIR="${RA_CLAUDE_SYNC_RUN_DIR:-/run/ra-claude-sync}"
LIB="${RA_CLAUDE_SYNC_LIB:-/usr/local/lib/ra-claude-sync/lib.sh}"
ENV_FILE="${RA_CLAUDE_SYNC_ENV_FILE:-/run/ra/env}"
STATUS_FILE="${RUN_DIR}/pull.json"
# Last-known-good workstation id, cached on the persistent home disk so a
# transient metadata blip can't flip our identity. See resolve_ws_id.
# shellcheck disable=SC2034  # read by resolve_ws_id in lib.sh
WS_ID_CACHE="${USER_HOME}/.ra-claude-sync/ws-id"

# shellcheck source=/dev/null
[ -r "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0

# Publish pull progress. $1 = state (running|done|failed); remaining
# fields come from the globals below and are optional.
PULL_STARTED_AT="${PULL_STARTED_AT:-$(date -u +%s)}"
PULL_NAMESPACES="${PULL_NAMESPACES:-0}"
PULL_FILES_RESTORED="${PULL_FILES_RESTORED:-0}"
write_status() {
    mkdir -p "${RUN_DIR}" 2>/dev/null || return 0
    local tmp; tmp="$(mktemp "${STATUS_FILE}.XXXXXX" 2>/dev/null)" || return 0
    jq -n --arg state "$1" \
        --argjson started "${PULL_STARTED_AT}" \
        --argjson finished "$([ "$1" = running ] && echo null || date -u +%s)" \
        --argjson namespaces "${PULL_NAMESPACES}" \
        --argjson files "${PULL_FILES_RESTORED}" \
        '{state: $state, started_at: $started, finished_at: $finished,
          namespaces: $namespaces, files_restored: $files}' > "${tmp}" 2>/dev/null \
        && chmod 0644 "${tmp}" && mv -f "${tmp}" "${STATUS_FILE}" || rm -f "${tmp}"
}

# --- Detach so the boot pull never blocks workstation startup ----------------
# The cross-namespace pull can move hundreds of MB across dozens of GCS
# namespaces and take many minutes. Run inline, it blocks the
# /etc/workstation-startup.d/ sequence long enough that Cloud Workstations
# tears the container down mid-boot — sshd never stabilizes and `ra connect`
# fails with "the workstation does not have a server running on port 22".
# Re-exec ourselves once, detached into a new session via `setsid --fork`
# (same pattern as the push daemon in 271_*.sh), and return immediately so
# boot completes; the pull then runs to completion in the background.
# RA_CLAUDE_SYNC_PULL_DETACHED guards against infinite re-exec; `claude-sync
# pull` sets it to run in the foreground.
#
# pull.json is marked "running" BEFORE we fork, so the push loop that 271_*.sh
# starts immediately after us always sees the pull in flight and waits.
if [ "${RA_CLAUDE_SYNC_PULL_DETACHED:-0}" != "1" ]; then
    export RA_CLAUDE_SYNC_PULL_DETACHED=1 PULL_STARTED_AT
    write_status running
    # Re-exec output is suppressed; capture a setsid failure so a non-running
    # boot pull is auditable in the boot journal instead of silently no-op'ing.
    if ! setsid --fork "$0" </dev/null >/dev/null 2>&1; then
        echo "[claude-sync-pull] WARNING: detached re-exec of '$0' failed;" \
             "boot pull skipped this boot" >&2
        write_status failed
    fi
    exit 0
fi

# Tee both stdout and stderr through to the shared log file so a sync
# regression leaves an auditable trail beyond the boot journal.
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[claude-sync-pull] $(date -u +%H:%M:%S) $*"; }

# Any exit that doesn't reach the end records "failed", so a crashed pull
# never leaves the push loop waiting on a stale "running".
PULL_STATE=failed
STAGE=""
cleanup() {
    if [ -n "${STAGE}" ]; then rm -rf "${STAGE}"; fi
    write_status "${PULL_STATE}"
}
trap cleanup EXIT
write_status running

if [ ! -r "${LIB}" ]; then
    log "ERROR: ${LIB} missing (image built before claude-sync 1.2.0?); skipping pull"
    exit 1
fi
# shellcheck source=/dev/null
. "${LIB}"

# chown only when we can (root on a workstation; tests run unprivileged).
fix_owner() {
    [ "$(id -u)" -eq 0 ] || return 0
    chown -R "${USER_NAME}:${USER_NAME}" "$@" 2>/dev/null || true
}

finish_noop() {
    log "$1"
    fix_owner "${USER_HOME}/.claude"
    PULL_STATE="done"
    exit 0
}

if [ -z "${RA_PLUGIN_CLAUDE_SYNC_BUCKET:-}" ]; then
    log "RA_PLUGIN_CLAUDE_SYNC_BUCKET unset; skipping"
    PULL_STATE="done"
    exit 0
fi

BUCKET="${RA_PLUGIN_CLAUDE_SYNC_BUCKET}"
select_namespace
PLUGIN_PREFIX="gs://${BUCKET}/claude-sync"
OWN_NS="${PLUGIN_PREFIX}/workstations/${WS_ID}/"

# Recency/age filter knobs (ADR 0004 #1). Namespaces accumulate
# one-per-workstation forever with no GC; the cross-namespace pull cost
# grew unbounded. We rank candidate namespaces by their manifest's
# last_push_at_epoch, then pull only those active within MAX_AGE_DAYS AND
# cap to the MAX_NAMESPACES most recent. Both are configurable via plugin
# config; defaults below match docs/adr/0004-load-reduction.md. Our own
# namespace is never subject to either.
MAX_AGE_DAYS="${RA_PLUGIN_CLAUDE_SYNC_PULL_MAX_AGE_DAYS:-30}"
MAX_NAMESPACES="${RA_PLUGIN_CLAUDE_SYNC_PULL_MAX_NAMESPACES:-15}"
case "${MAX_AGE_DAYS}" in *[!0-9]*|"") MAX_AGE_DAYS=30 ;; esac
case "${MAX_NAMESPACES}" in *[!0-9]*|"") MAX_NAMESPACES=15 ;; esac
INTERVAL="${RA_PLUGIN_CLAUDE_SYNC_INTERVAL_SECONDS:-60}"
case "${INTERVAL}" in *[!0-9]*|"") INTERVAL=60 ;; esac

log "starting pull as ws-id=${WS_ID} writer=${WRITER_ID} from ${PLUGIN_PREFIX} (max_age_days=${MAX_AGE_DAYS} max_namespaces=${MAX_NAMESPACES})"

mkdir -p "${USER_HOME}/.claude"

# Another live instance pushing to our namespace is worth knowing at boot:
# it means `ra create` gave two workstations the same stable id.
check_shared_writer "${PLUGIN_PREFIX}/_manifest/${WS_ID}.json" $(( INTERVAL * 3 )) || true

# List namespaces. `gcloud storage ls` returns one
# `gs://bucket/claude-sync/workstations/<ws>/` per line; an
# empty/nonexistent prefix is not an error here.
mapfile -t NAMESPACES < <(gcloud storage ls "${PLUGIN_PREFIX}/workstations/" 2>>"${LOG_FILE}" | sort -u || true)

if [ "${#NAMESPACES[@]}" -eq 0 ]; then
    finish_noop "no namespaces under ${PLUGIN_PREFIX}/workstations/ — first boot"
fi

# --- Recency/age-filtered + capped namespace selection (ADR 0004 #1) ---------
# Without GC, every past `ra create` leaves an ~85 MB namespace behind, so
# an unfiltered pull rsyncs gigabytes across dozens of dead namespaces on
# every boot. Rank by each manifest's last_push_at_epoch and pull only the
# namespaces that are (a) newer than MAX_AGE_DAYS and (b) within the
# MAX_NAMESPACES most-recent. Our own WS_ID bypasses both and is pulled
# first. A missing/invalid manifest is treated as epoch 0 — the oldest
# possible — so undated namespaces fall off first and never crowd out a
# dated, active one. Every inclusion and exclusion is logged; nothing is
# silently truncated.
#
# now/cutoff in epoch seconds; cutoff=0 disables the age gate when
# MAX_AGE_DAYS=0 (cap-only mode).
now_epoch="$(date -u +%s)"
if [ "${MAX_AGE_DAYS}" -gt 0 ]; then
    cutoff_epoch=$(( now_epoch - MAX_AGE_DAYS * 86400 ))
else
    cutoff_epoch=0
fi

# Fetch all namespace manifests in ONE gcloud round-trip instead of one
# `gcloud storage cat` per namespace — ranking N namespaces otherwise pays
# N gcloud cold-starts (tens of seconds, and N chances to flake). Mirror
# them locally, best-effort: a namespace whose manifest is missing or
# unreadable falls through to epoch 0 below (treated as oldest), as before.
manifest_dir="$(mktemp -d)"
gcloud storage rsync --recursive \
    "${PLUGIN_PREFIX}/_manifest/" "${manifest_dir}/" 2>>"${LOG_FILE}" || true

# Build "<epoch>\t<namespace-uri>" rows for every candidate other than our
# own, reading each manifest from the local mirror. Then sort newest-first
# and apply the TTL + cap.
PULL_NS=()
ranked_rows=""
for ns in "${NAMESPACES[@]}"; do
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    [ -z "${ns_id}" ] && continue
    if [ "${ns_id}" = "${WS_ID}" ]; then
        log "include ${ns_id}: own namespace (restore; exempt from age/cap filter)"
        PULL_NS+=("${ns}")
        continue
    fi
    ts="$(jq -r '.last_push_at_epoch // 0' "${manifest_dir}/${ns_id}.json" 2>>"${LOG_FILE}" || echo 0)"
    ts="${ts:-0}"
    case "${ts}" in *[!0-9]*) ts=0 ;; esac
    ranked_rows+="${ts}	${ns}"$'\n'
done
rm -rf "${manifest_dir}"

# Sort by epoch descending (newest first). `sort -rn` keys on the leading
# numeric epoch field; the tab-separated URI rides along untouched.
mapfile -t ranked_sorted < <(printf '%s' "${ranked_rows}" | sort -rn -k1,1 | sed '/^$/d')

kept=0
for row in "${ranked_sorted[@]}"; do
    ts="${row%%	*}"
    ns="${row#*	}"
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    # Age gate (skipped when cutoff_epoch=0). ts=0 (missing/invalid
    # manifest) always fails a non-zero cutoff, so undated namespaces are
    # dropped first — exactly the intended "oldest" treatment.
    if [ "${cutoff_epoch}" -gt 0 ] && [ "${ts}" -lt "${cutoff_epoch}" ]; then
        if [ "${ts}" -eq 0 ]; then
            log "skip ${ns_id}: no/invalid manifest (treated as oldest, beyond ${MAX_AGE_DAYS}d TTL)"
        else
            log "skip ${ns_id}: last_push_at_epoch=${ts} older than ${MAX_AGE_DAYS}d TTL (cutoff=${cutoff_epoch})"
        fi
        continue
    fi
    # Recency cap.
    if [ "${kept}" -ge "${MAX_NAMESPACES}" ]; then
        log "skip ${ns_id}: beyond top-${MAX_NAMESPACES} recency cap (last_push_at_epoch=${ts})"
        continue
    fi
    PULL_NS+=("${ns}")
    kept=$((kept + 1))
done

PULL_NAMESPACES="${#PULL_NS[@]}"
log "selected ${PULL_NAMESPACES} of ${#NAMESPACES[@]} namespace(s) for pull (${kept} other + own if present)"
if [ "${PULL_NAMESPACES}" -eq 0 ]; then
    finish_noop "no eligible namespaces after age/cap filter — nothing to pull"
fi

# Stage everything into a tmpdir so the existing live tree is unaffected
# until we cp-no-clobber / merge on top.
STAGE="$(mktemp -d)"
mkdir -p "${STAGE}/history" "${STAGE}/claudejson"

# A missing dir counts as 0. `|| true` because find fails on it and
# pipefail + set -e would otherwise abort the pull on a fresh disk.
count_files() { find "$1" -type f 2>/dev/null | wc -l || true; }
local_projects_before="$(count_files "${USER_HOME}/.claude/projects")"
own_remote_files=0

for ns in "${PULL_NS[@]}"; do
    ns_id="${ns%/}"; ns_id="${ns_id##*/}"
    [ -z "${ns_id}" ] && continue
    log "staging namespace ${ns_id}"
    for sub in projects todos plans session-env; do
        mkdir -p "${STAGE}/${sub}"
        gcloud storage rsync --recursive \
            "${ns}${sub}/" "${STAGE}/${sub}/" 2>>"${LOG_FILE}" || true
    done
    # Own namespace is staged first (PULL_NS order), so the stage holds
    # exactly its files at this point.
    if [ "${ns}" = "${OWN_NS}" ]; then
        own_remote_files="$(count_files "${STAGE}/projects")"
    fi
    # Single-file, merge-on-read members: stage one copy per namespace so
    # the union merge below can fold them all in.
    gcloud storage cp "${ns}history.jsonl" "${STAGE}/history/${ns_id}.jsonl" 2>>"${LOG_FILE}" || true
    gcloud storage cp "${ns}claude.json"   "${STAGE}/claudejson/${ns_id}.json" 2>>"${LOG_FILE}" || true
done

# A populated own namespace landing on an empty local tree is the
# rebuilt-workstation case that used to restore nothing. Call it out so
# the log shows the restore happened (or, on an old image, didn't).
if [ "${local_projects_before}" -eq 0 ] && [ "${own_remote_files}" -gt 100 ]; then
    log "WARN: fresh local state with ${own_remote_files} file(s) in own namespace — restoring from ${WS_ID}"
fi

# Merge staged directory content into ~/.claude using `cp -an` (archive +
# no-clobber) so any newer local file wins. First-time fetches still
# populate empty subtrees.
for sub in projects todos plans session-env; do
    [ -d "${STAGE}/${sub}" ] || continue
    mkdir -p "${USER_HOME}/.claude/${sub}"
    before="$(count_files "${USER_HOME}/.claude/${sub}")"
    cp -an "${STAGE}/${sub}/." "${USER_HOME}/.claude/${sub}/" 2>>"${LOG_FILE}" || true
    added=$(( $(count_files "${USER_HOME}/.claude/${sub}") - before ))
    PULL_FILES_RESTORED=$(( PULL_FILES_RESTORED + added ))
    if [ "${added}" -gt 0 ]; then log "restored ${added} file(s) into ${sub}/"; fi
done

# Union-merge the append-only / shared single files.
log "union-merging history.jsonl across $(ls -1 "${STAGE}/history" 2>/dev/null | wc -l) namespace(s) + local"
merge_jsonl_history "${USER_HOME}/.claude/history.jsonl" "${STAGE}"/history/*.jsonl

log "merging .claude.json project history across $(ls -1 "${STAGE}/claudejson" 2>/dev/null | wc -l) namespace(s)"
merge_claude_json "${USER_HOME}/.claude.json" "${STAGE}"/claudejson/*.json

fix_owner "${USER_HOME}/.claude"
if [ -f "${USER_HOME}/.claude.json" ]; then fix_owner "${USER_HOME}/.claude.json"; fi
if [ -f "${WS_ID_CACHE}" ]; then fix_owner "$(dirname "${WS_ID_CACHE}")"; fi
PULL_STATE="done"
log "done: ${PULL_NAMESPACES} namespace(s), ${PULL_FILES_RESTORED} file(s) restored"
