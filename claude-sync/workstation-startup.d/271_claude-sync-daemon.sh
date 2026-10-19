#!/bin/bash
# claude-sync plugin — install + start the push loop.
#
# Materializes /usr/local/bin/ra-claude-sync-loop.sh and the operator
# command /usr/local/bin/claude-sync, then starts the loop.
# Tries the systemd path first (writes /etc/systemd/system/ra-claude-sync.service
# and enables/starts it). When systemd is not PID 1, falls back to a setsid-
# detached background process (mirroring the marimo plugin's daemon pattern).
#
# Why the fallback exists: Cloud Workstations' default base image runs
# `/google/scripts/entrypoint.sh` as PID 1 — NOT systemd — so `systemctl`
# calls succeed at the binary level but fail to register the unit with any
# init system. Before this fallback, the push loop was never starting in
# production: the unit file landed on disk and nothing ever exec'd it.
#
# Idempotent: re-running overwrites the loop script and (in fallback mode)
# kills the previous loop process before relaunching, so config changes
# (e.g. new interval_seconds) take effect on the next boot.
#
# Runs as root so it inherits the workstation service-account auth that
# gcloud picks up from the metadata server, and can read /home/user/.claude/
# regardless of file mode quirks. All loop chatter goes to
# /var/log/ra-claude-sync.log so operators can diagnose sync regressions
# without bouncing the workstation just to read the journal.
#
# RA_CLAUDE_SYNC_BIN_DIR / RA_CLAUDE_SYNC_INSTALL_ONLY exist for tests/run.sh
# only: install the scripts into a scratch dir and skip starting the loop.
set -euo pipefail

ENV_FILE="${RA_CLAUDE_SYNC_ENV_FILE:-/run/ra/env}"
# shellcheck source=/dev/null
[ -r "${ENV_FILE}" ] && set -a && . "${ENV_FILE}" && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0

BIN_DIR="${RA_CLAUDE_SYNC_BIN_DIR:-/usr/local/bin}"
LOOP_PATH="${BIN_DIR}/ra-claude-sync-loop.sh"
CLI_PATH="${BIN_DIR}/claude-sync"
UNIT_PATH="/etc/systemd/system/ra-claude-sync.service"
LOG_FILE="/var/log/ra-claude-sync.log"
# Pidfile must agree with the path the loop script writes to. Lives in
# /run so it auto-clears on reboot — any leftover PID would refer to a
# vanished process anyway.
PID_FILE="/run/ra-claude-sync.pid"

mkdir -p "${BIN_DIR}"
cat > "${LOOP_PATH}" <<'LOOP_EOF'
#!/bin/bash
# ra-claude-sync push loop — installed by 271_claude-sync-daemon.sh.
#
# Waits for /run/ra/env (the core 200_*.sh boot script writes it on
# every boot) and for the boot pull to finish, then pushes a filtered
# allowlist of /home/user/.claude/ to
# gs://${BUCKET}/claude-sync/workstations/${WS_ID}/ every ${INTERVAL}
# seconds. All data lives under the claude-sync/ prefix so other plugins
# can share the same bucket without collisions.
#
# Usage: ra-claude-sync-loop.sh [--once]
#   --once  run a single push cycle (no pidfile, no pull wait) and exit
#           non-zero if the cycle was incomplete. Used by `claude-sync push`.
#
# Push integrity (see docs/adr/0002-merge-based-sync.md, 0006-*):
#   * history.jsonl and claude.json are MERGED with the remote copy before
#     upload (read-modify-write guarded by --if-generation-match), never
#     overwritten: a fresh disk, or a second workstation sharing this
#     namespace, can no longer erase remote history.
#   * history.jsonl is sanitized (torn/invalid lines dropped) before
#     upload so a line caught mid-append never ships.
#   * .claude.json is JSON-validated before upload; a torn read is
#     skipped for the cycle.
#   * the manifest is advanced ONLY when every push in the cycle
#     succeeded, so a partial/failed push never advertises itself as
#     "freshest". It also records which instance wrote it, so a second
#     live writer on the same namespace is logged as a WARN.
#
# All gcloud chatter is appended to /var/log/ra-claude-sync.log so a
# silent regression in steady state is auditable. Exits with status 1
# on any unrecoverable startup error (env never appears, plugin
# disabled at startup). Under systemd the Restart=always policy retries;
# under the setsid fallback the loop simply dies until the next
# workstation reboot re-runs 271_*.sh.
#
# The RA_CLAUDE_SYNC_* path overrides below exist for tests/run.sh only.
set -uo pipefail

ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

USER_HOME="${RA_CLAUDE_SYNC_USER_HOME:-/home/user}"
LOG_FILE="${RA_CLAUDE_SYNC_LOG_FILE:-/var/log/ra-claude-sync.log}"
PID_FILE="${RA_CLAUDE_SYNC_PID_FILE:-/run/ra-claude-sync.pid}"
RUN_DIR="${RA_CLAUDE_SYNC_RUN_DIR:-/run/ra-claude-sync}"
LIB="${RA_CLAUDE_SYNC_LIB:-/usr/local/lib/ra-claude-sync/lib.sh}"
ENV_FILE="${RA_CLAUDE_SYNC_ENV_FILE:-/run/ra/env}"
PULL_WAIT_SECONDS="${RA_CLAUDE_SYNC_PULL_WAIT_SECONDS:-1800}"
# Last-known-good workstation id, cached on the persistent home disk.
# shellcheck disable=SC2034  # read by resolve_ws_id in lib.sh
WS_ID_CACHE="${USER_HOME}/.ra-claude-sync/ws-id"

mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${PID_FILE}")"
if [ "${ONCE}" -eq 1 ]; then
    # Interactive one-shot: echo to the terminal as well as the log.
    exec > >(tee -a "${LOG_FILE}") 2>&1
else
    exec >> "${LOG_FILE}" 2>&1
    # Record our PID so 271_*.sh can find and stop us idempotently on the
    # next boot. Cleaned up on exit. The pidfile is informational under
    # systemd (which tracks the process itself) but is the authoritative
    # handle under the setsid fallback path. A --once run must not touch
    # it, or it would orphan the running daemon's handle.
    echo $$ > "${PID_FILE}"
    trap 'rm -f "${PID_FILE}"' EXIT
fi

log() { echo "[claude-sync-loop] $(date -u +%H:%M:%S) $*"; }

if [ ! -r "${LIB}" ]; then
    log "${LIB} missing (image built before claude-sync 1.2.0?); exiting 1"
    exit 1
fi
# shellcheck source=/dev/null
. "${LIB}"

# Wait up to 5 minutes for /run/ra/env to be populated. On a fresh
# workstation boot, this systemd unit may start before the core
# workstation-startup.d/200_*.sh has run. After the timeout we exit 1
# so systemd's Restart=always kicks in with backoff instead of leaving
# the service quietly stalled.
ready=0
for _ in $(seq 1 60); do
    if [ -r "${ENV_FILE}" ]; then
        ready=1
        break
    fi
    sleep 5
done
if [ "${ready}" -ne 1 ]; then
    log "${ENV_FILE} not present after 5min; exiting 1 so systemd restarts us"
    exit 1
fi

# shellcheck source=/dev/null
set -a && . "${ENV_FILE}" && set +a

if [ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" != "true" ]; then
    log "plugin disabled at startup; exiting 1 so systemd restarts us if env later changes"
    exit 1
fi
if [ -z "${RA_PLUGIN_CLAUDE_SYNC_BUCKET:-}" ]; then
    log "RA_PLUGIN_CLAUDE_SYNC_BUCKET unset at startup; exiting 1"
    exit 1
fi

BUCKET="${RA_PLUGIN_CLAUDE_SYNC_BUCKET}"
INTERVAL="${RA_PLUGIN_CLAUDE_SYNC_INTERVAL_SECONDS:-60}"
case "${INTERVAL}" in *[!0-9]*|"") INTERVAL=60 ;; esac
case "${PULL_WAIT_SECONDS}" in *[!0-9]*|"") PULL_WAIT_SECONDS=1800 ;; esac

# Metadata is up by now (we waited for /run/ra/env, well after boot), so
# the writer id resolves authoritatively and is cached.
select_namespace
WRITER_SINCE="$(date -u +%s)"

PREFIX="gs://${BUCKET}/claude-sync/workstations/${WS_ID}"
MANIFEST_PATH="gs://${BUCKET}/claude-sync/_manifest/${WS_ID}.json"

# Hold the first push until the boot pull has merged remote state in.
# A missing pull.json means no pull ran this boot (plugin pull disabled, or
# an old image): don't wait. The ceiling is only a backstop for a pull
# killed hard enough to skip its EXIT trap; pushes merge with the remote
# (below), so pushing early is safe, just noisier.
wait_for_pull() {
    local f="${RUN_DIR}/pull.json" state waited=0
    [ -f "${f}" ] || return 0
    while :; do
        state="$(jq -r '.state // ""' "${f}" 2>/dev/null || true)"
        if [ "${state}" != "running" ]; then
            [ "${waited}" -gt 0 ] && log "boot pull finished (state=${state}) after ${waited}s; starting pushes"
            return 0
        fi
        if [ "${waited}" -ge "${PULL_WAIT_SECONDS}" ]; then
            log "WARN: boot pull still running after ${waited}s; starting pushes anyway (they merge, not overwrite)"
            return 0
        fi
        [ "${waited}" -eq 0 ] && log "waiting for boot pull to finish before first push"
        sleep 5
        waited=$(( waited + 5 ))
    done
}

# Current generation of a remote object, or 0 if it doesn't exist (or
# can't be described — the upload's precondition then fails and we retry).
remote_generation() {
    local gen
    gen="$(gcloud storage objects describe "$1" --format='value(generation)' 2>/dev/null || true)"
    case "${gen}" in ''|*[!0-9]*) gen=0 ;; esac
    printf '%s' "${gen}"
}

# Read-modify-write a single-file member so concurrent writers converge on
# the union instead of overwriting each other.
#   $1 = remote object ; $2 = prepared local copy ; $3 = merge function
#   (merge_jsonl_history | merge_claude_json, called as `$3 <out> <remote>`).
# Uploads with --if-generation-match so a writer that raced us forces a
# re-read rather than being clobbered. Returns non-zero after 3 lost races
# or failed uploads (the caller then withholds the manifest).
push_merged() {
    local obj="$1" src="$2" merge="$3" attempt gen remote out
    for attempt in 1 2 3; do
        gen="$(remote_generation "${obj}")"
        remote="$(mktemp)"; out="$(mktemp)"
        if [ "${gen}" != 0 ] && ! gcloud storage cp "${obj}#${gen}" "${remote}" 2>/dev/null; then
            # Overwritten between describe and download; re-read.
            rm -f "${remote}" "${out}"
            continue
        fi
        cp "${src}" "${out}"
        "${merge}" "${out}" "${remote}"
        if gcloud storage cp --if-generation-match="${gen}" "${out}" "${obj}"; then
            rm -f "${remote}" "${out}"
            return 0
        fi
        log "upload of ${obj##*/} lost a race or failed (attempt ${attempt}/3)"
        rm -f "${remote}" "${out}"
    done
    return 1
}

# Upload history.jsonl (torn/invalid lines stripped) merged with the remote
# copy. Returns non-zero only if the upload itself failed (so the caller can
# withhold the manifest); a file that is absent or has no valid lines is a
# no-op success.
push_history() {
    local src="${USER_HOME}/.claude/history.jsonl" tmp rc=0
    [ -f "${src}" ] || return 0
    tmp="$(mktemp)"
    jq -R -c 'fromjson? // empty' "${src}" > "${tmp}" 2>>"${LOG_FILE}" || true
    if [ -s "${tmp}" ]; then
        push_merged "${PREFIX}/history.jsonl" "${tmp}" merge_jsonl_history || rc=1
    else
        log "history.jsonl had no valid lines this cycle; skipping its push"
    fi
    rm -f "${tmp}"
    return "${rc}"
}

# Upload .claude.json, with the remote copy's per-project history unioned in,
# only if the local file is currently valid JSON (a mid-write read is
# skipped). The local file itself is never modified. A skipped invalid read
# is not a push failure.
push_claude_json() {
    local src="${USER_HOME}/.claude.json" tmp rc=0
    [ -f "${src}" ] || return 0
    tmp="$(mktemp)"
    cp "${src}" "${tmp}"
    if jq -e . "${tmp}" >/dev/null 2>&1; then
        push_merged "${PREFIX}/claude.json" "${tmp}" merge_claude_json || rc=1
    else
        log ".claude.json not valid JSON this cycle; skipping its push"
    fi
    rm -f "${tmp}"
    return "${rc}"
}

# Rate limit for the shared-writer WARN (once per hour, not every cycle).
LAST_SHARED_WARN=0

push_once() {
    local ok=1 sub
    for sub in projects todos plans session-env; do
        if [ -d "${USER_HOME}/.claude/${sub}" ]; then
            gcloud storage rsync --recursive \
                "${USER_HOME}/.claude/${sub}/" "${PREFIX}/${sub}/" || ok=0
        fi
    done
    push_history    || ok=0
    push_claude_json || ok=0

    # Before we overwrite the manifest, see whether a different instance
    # wrote it recently: two live workstations on one namespace.
    local now; now="$(date -u +%s)"
    if [ $(( now - LAST_SHARED_WARN )) -ge 3600 ] \
        && check_shared_writer "${MANIFEST_PATH}" $(( INTERVAL * 3 )); then
        LAST_SHARED_WARN="${now}"
    fi

    # Manifest carries last_push_at so the boot pull can rank namespaces
    # and operators can see when each namespace last fully synced, plus the
    # writer instance for shared-namespace detection. Advance it ONLY on a
    # fully-successful cycle so it never points at a namespace whose data
    # upload failed.
    if [ "${ok}" -eq 1 ]; then
        local iso tmp
        iso=$(date -u -d "@${now}" +"%Y-%m-%dT%H:%M:%SZ")
        tmp=$(mktemp)
        jq -n --arg iso "${iso}" --argjson ts "${now}" \
            --arg writer "${WRITER_ID}" --argjson since "${WRITER_SINCE}" \
            '{last_push_at: $iso, last_push_at_epoch: $ts, writer: $writer, writer_since: $since}' > "${tmp}"
        gcloud storage cp "${tmp}" "${MANIFEST_PATH}" || log "manifest upload failed"
        rm -f "${tmp}"
        return 0
    fi
    log "push cycle incomplete; not advancing manifest"
    return 1
}

if [ "${ONCE}" -eq 1 ]; then
    log "one-shot push ws-id=${WS_ID} writer=${WRITER_ID} prefix=${PREFIX}"
    push_once
    exit $?
fi

log "starting push loop ws-id=${WS_ID} writer=${WRITER_ID} interval=${INTERVAL}s prefix=${PREFIX}"
wait_for_pull

while true; do
    push_once
    sleep "${INTERVAL}"
done
LOOP_EOF
chmod 0755 "${LOOP_PATH}"

cat > "${CLI_PATH}" <<'CLI_EOF'
#!/bin/bash
# claude-sync — operator command, installed by 271_claude-sync-daemon.sh.
#
#   claude-sync pull     merge remote state into ~/.claude now (foreground, streams the log)
#   claude-sync push     run one push cycle now
#   claude-sync status   show bucket, namespace, loop, last pull/push, and warnings
#
# pull/push re-exec under sudo: they need root for the log file, chown,
# and the service-account gcloud auth the boot scripts use.
set -euo pipefail

PULL_SCRIPT="/etc/workstation-startup.d/270_claude-sync-pull.sh"
LOOP_SCRIPT="/usr/local/bin/ra-claude-sync-loop.sh"
PID_FILE="/run/ra-claude-sync.pid"
RUN_DIR="/run/ra-claude-sync"
LOG_FILE="/var/log/ra-claude-sync.log"

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else exec sudo "$@"; fi
}

load_env() {
    if [ -r /run/ra/env ]; then set -a; . /run/ra/env; set +a; fi
}

status() {
    load_env
    local bucket="${RA_PLUGIN_CLAUDE_SYNC_BUCKET:-}" ns="${RA_PLUGIN_CLAUDE_SYNC_NAMESPACE:-}"
    echo "enabled:    ${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}"
    echo "bucket:     ${bucket:-<unset>}"
    echo "namespace:  ${ns:-<unset; falls back to instance name>}"
    local pid=""
    [ -r "${PID_FILE}" ] && pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "push loop:  running (pid ${pid}, every ${RA_PLUGIN_CLAUDE_SYNC_INTERVAL_SECONDS:-60}s)"
    else
        echo "push loop:  NOT running (restart: sudo /etc/workstation-startup.d/271_claude-sync-daemon.sh)"
    fi
    if [ -r "${RUN_DIR}/pull.json" ]; then
        jq -r '"last pull:  \(.state), \(.namespaces) namespace(s), \(.files_restored) file(s) restored"
               + (if .finished_at then ", finished \(.finished_at | todate)" else "" end)' "${RUN_DIR}/pull.json"
    else
        echo "last pull:  none recorded this boot"
    fi
    [ -n "${bucket}" ] && [ -n "${ns}" ] || return 0
    local prefix="gs://${bucket}/claude-sync" manifest now writer ts
    now="$(date -u +%s)"
    manifest="$(gcloud storage cat "${prefix}/_manifest/${ns}.json" 2>/dev/null || true)"
    if [ -n "${manifest}" ]; then
        writer="$(jq -r '.writer // "unknown"' <<<"${manifest}")"
        ts="$(jq -r '.last_push_at_epoch // 0' <<<"${manifest}")"
        echo "last push:  $(( now - ts ))s ago by ${writer}"
        local me
        me="$(curl -fs -H 'Metadata-Flavor: Google' \
            'http://metadata.google.internal/computeMetadata/v1/instance/name' 2>/dev/null || hostname)"
        if [ "${writer}" != "unknown" ] && [ "${writer}" != "${me}" ] \
            && [ $(( now - ts )) -le $(( ${RA_PLUGIN_CLAUDE_SYNC_INTERVAL_SECONDS:-60} * 3 )) ]; then
            echo "WARNING:    another live workstation (${writer}) pushes to this namespace; this is ${me}"
        fi
    else
        echo "last push:  no manifest yet"
    fi
    local remote local_n
    remote="$(gcloud storage ls -r "${prefix}/workstations/${ns}/projects/**" 2>/dev/null | grep -c '^gs://' || true)"
    local_n="$(find "${HOME}/.claude/projects" -type f 2>/dev/null | wc -l)"
    echo "projects/:  ${local_n} file(s) local, ${remote} in own namespace"
    echo "log:        ${LOG_FILE}"
}

case "${1:-}" in
    pull) as_root env RA_CLAUDE_SYNC_PULL_DETACHED=1 "${PULL_SCRIPT}" ;;
    push) as_root "${LOOP_SCRIPT}" --once ;;
    status) status ;;
    *) sed -n '4,6p' "$0" | sed 's/^# //'; exit 2 ;;
esac
CLI_EOF
chmod 0755 "${CLI_PATH}"

[ "${RA_CLAUDE_SYNC_INSTALL_ONLY:-0}" = "1" ] && exit 0

# PID 1 detection. Cloud Workstations' default image runs
# /google/scripts/entrypoint.sh as PID 1, so /proc/1/comm reads as
# "entrypoint.sh", not "systemd". Note: `systemctl` may still be on
# PATH (Dockerfile.d's soft-assert doesn't catch this) but without
# systemd-as-PID-1 the daemon-reload / enable calls are no-ops.
have_systemd_pid1() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]
}

start_via_systemd() {
    cat > "${UNIT_PATH}" <<'UNIT_EOF'
[Unit]
Description=ra claude-sync push loop (sync ~/.claude to GCS)
After=network-online.target
Wants=network-online.target
# Restart=always combined with a generous burst window: if startup
# fails (env not ready, plugin disabled), we want systemd to keep
# retrying with backoff rather than parking the unit silently.
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
ExecStart=/usr/local/bin/ra-claude-sync-loop.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT_EOF

    systemctl daemon-reload
    # --no-block so we don't wait on the unit's initial cycle.
    systemctl enable --now --no-block ra-claude-sync.service || true
    # `restart` so subsequent `ra create` runs that mutate env take effect.
    systemctl restart ra-claude-sync.service || true
    echo "[claude-sync-daemon] ra-claude-sync.service installed and started (logs: ${LOG_FILE})"
}

start_via_setsid() {
    mkdir -p "$(dirname "${LOG_FILE}")"

    # Idempotency: a re-run of 271_*.sh (or a manual invocation) should
    # not produce two parallel loops. The loop script writes its own PID
    # to PID_FILE on start (cleared on exit). Use that PID directly rather
    # than pgrep-by-pattern, which would also match the calling shell's
    # command line whenever the loop path happens to appear in it (e.g. a
    # shell session that just `cat`ed the script).
    if [ -f "${PID_FILE}" ]; then
        old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        # Validate before kill: empty, non-numeric, or dead-PID values
        # all fall through to the harmless `rm -f` below. Matches the
        # case-pattern style used elsewhere in this file (see INTERVAL
        # validation in the loop body).
        case "${old_pid}" in
            ''|*[!0-9]*)
                ;;
            *)
                if kill -0 "${old_pid}" 2>/dev/null; then
                    echo "[claude-sync-daemon] stopping existing loop pid=${old_pid}"
                    kill "${old_pid}" 2>/dev/null || true
                    # Give the previous loop up to 5s to exit cleanly before SIGKILL.
                    for _ in 1 2 3 4 5; do
                        kill -0 "${old_pid}" 2>/dev/null || break
                        sleep 1
                    done
                    kill -9 "${old_pid}" 2>/dev/null || true
                fi
                ;;
        esac
        rm -f "${PID_FILE}"
    fi

    # setsid --fork detaches the loop into its own session/process-group
    # so it survives this startup script's exit (matches the marimo plugin
    # pattern). The loop script does its own log redirection internally,
    # writes its PID to PID_FILE, and clears it on exit, so we don't need
    # to capture the PID here.
    setsid --fork "${LOOP_PATH}" </dev/null
    echo "[claude-sync-daemon] loop started via setsid (PID 1 is $(cat /proc/1/comm 2>/dev/null || echo unknown); logs: ${LOG_FILE})"
}

if have_systemd_pid1; then
    start_via_systemd
else
    start_via_setsid
fi
