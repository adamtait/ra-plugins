#!/bin/bash
# claude-sync plugin — install + start the push loop.
#
# Materializes /usr/local/bin/ra-claude-sync-loop.sh and starts it.
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
set -euo pipefail

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SYNC_ENABLED:-false}" = "true" ] || exit 0

LOOP_PATH="/usr/local/bin/ra-claude-sync-loop.sh"
UNIT_PATH="/etc/systemd/system/ra-claude-sync.service"
LOG_FILE="/var/log/ra-claude-sync.log"
# Pidfile must agree with the path the loop script writes to. Lives in
# /run so it auto-clears on reboot — any leftover PID would refer to a
# vanished process anyway.
PID_FILE="/run/ra-claude-sync.pid"

COMMON_PATH="/usr/local/lib/ra-claude-sync/common.sh"
if [ ! -r "${COMMON_PATH}" ]; then
    # 270_*.sh installs the shared helpers and always runs first; if it
    # failed, refuse to start a loop that cannot resolve its namespace.
    echo "[claude-sync-daemon] ERROR: ${COMMON_PATH} missing (did 270_claude-sync-pull.sh run?); not starting the push loop" >&2
    exit 1
fi

cat > "${LOOP_PATH}" <<'LOOP_EOF'
#!/bin/bash
# ra-claude-sync push loop — installed by 271_claude-sync-daemon.sh.
#
# Waits for /run/ra/env (the core 200_*.sh boot script writes it on
# every boot), then pushes a filtered allowlist of /home/user/.claude/
# to gs://${BUCKET}/claude-sync/workstations/${WS_ID}/ every ${INTERVAL}
# seconds, where WS_ID is this workstation's OWN namespace
# (`<stable-id>--<hostname>`, see docs/adr/0006-per-workstation-namespace.md).
# Every pull_interval_seconds it also runs ra-claude-sync-pull.sh so other
# workstations' sessions arrive without waiting for a reboot.
#
# Push integrity (see docs/adr/0002-merge-based-sync.md):
#   * history.jsonl is sanitized (torn/invalid lines dropped) before
#     upload so a line caught mid-append never ships.
#   * .claude.json is JSON-validated before upload; a torn read is
#     skipped for the cycle.
#   * the manifest is advanced ONLY when every push in the cycle
#     succeeded, so a partial/failed push never advertises itself as
#     "freshest".
#
# Single-writer guard (ADR 0006): the manifest records which instance
# wrote it. At startup, if a DIFFERENT instance pushed to our namespace
# recently, the loop exits instead of overwriting that workstation's data.
#
# All gcloud chatter is appended to /var/log/ra-claude-sync.log. Exits
# with status 1 on any unrecoverable startup error. Under systemd the
# Restart=always policy retries; under the setsid fallback the loop simply
# dies until the next workstation reboot re-runs 271_*.sh.
set -uo pipefail

LOG_TAG="claude-sync-loop"
# shellcheck source=/dev/null
. "${RA_CLAUDE_SYNC_COMMON:-/usr/local/lib/ra-claude-sync/common.sh}"
PID_FILE="/run/ra-claude-sync.pid"
PULL_PATH="/usr/local/bin/ra-claude-sync-pull.sh"

mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${PID_FILE}")"
exec >> "${LOG_FILE}" 2>&1

# Record our PID so 271_*.sh can find and stop us idempotently on the
# next boot. Cleaned up on exit. The pidfile is informational under
# systemd (which tracks the process itself) but is the authoritative
# handle under the setsid fallback path.
echo $$ > "${PID_FILE}"
trap 'rm -f "${PID_FILE}"' EXIT

# Wait up to 5 minutes for /run/ra/env to be populated. After the timeout
# we exit 1 so systemd's Restart=always kicks in with backoff instead of
# leaving the service quietly stalled.
ready=0
for _ in $(seq 1 60); do
    if [ -r /run/ra/env ]; then
        ready=1
        break
    fi
    sleep 5
done
if [ "${ready}" -ne 1 ]; then
    log "/run/ra/env not present after 5min; exiting 1 so systemd restarts us"
    exit 1
fi

set -a && . /run/ra/env && set +a

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
PULL_INTERVAL="${RA_PLUGIN_CLAUDE_SYNC_PULL_INTERVAL_SECONDS:-600}"
case "${PULL_INTERVAL}" in *[!0-9]*|"") PULL_INTERVAL=600 ;; esac

# Metadata is up by now (we waited for /run/ra/env, well after boot).
resolve_namespace
WRITER_HOST="$(hostname 2>/dev/null || true)"
WRITER_INSTANCE="$(instance_name)"

PREFIX="gs://${BUCKET}/claude-sync/workstations/${WS_ID}"
MANIFEST_PATH="gs://${BUCKET}/claude-sync/_manifest/${WS_ID}.json"

# Single-writer guard. A manifest written by a different instance within
# the last 3 push intervals means another live workstation owns this
# namespace; pushing would overwrite its history.jsonl / claude.json.
# A stale foreign manifest (e.g. the previous instance of a workstation
# rebuilt under the same name) is fine — we take the namespace over.
existing_manifest="$(gcloud storage cat "${MANIFEST_PATH}" 2>/dev/null || true)"
if [ -n "${existing_manifest}" ] && [ -n "${WRITER_INSTANCE}" ]; then
    other_instance="$(printf '%s' "${existing_manifest}" | jq -r '.writer_instance // empty' 2>/dev/null || true)"
    other_epoch="$(printf '%s' "${existing_manifest}" | jq -r '.last_push_at_epoch // 0' 2>/dev/null || echo 0)"
    case "${other_epoch}" in *[!0-9]*|"") other_epoch=0 ;; esac
    age=$(( $(date -u +%s) - other_epoch ))
    if [ -n "${other_instance}" ] && [ "${other_instance}" != "${WRITER_INSTANCE}" ] \
        && [ "${age}" -lt $(( 3 * INTERVAL )) ]; then
        log "ERROR namespace collision: ${WS_ID} was pushed ${age}s ago by instance ${other_instance} (we are ${WRITER_INSTANCE}); refusing to push. See docs/adr/0006-per-workstation-namespace.md"
        exit 1
    fi
fi

log "starting push loop ws-id=${WS_ID} interval=${INTERVAL}s pull_interval=${PULL_INTERVAL}s prefix=${PREFIX}"

# Upload history.jsonl with torn/invalid lines stripped. Returns non-zero
# only if the upload itself failed (so the caller can withhold the
# manifest); a file that is absent or has no valid lines is a no-op success.
push_history() {
    local src="${USER_HOME}/.claude/history.jsonl" tmp
    [ -f "${src}" ] || return 0
    tmp="$(mktemp)"
    jq -R -c 'fromjson? // empty' "${src}" > "${tmp}" 2>>"${LOG_FILE}" || true
    if [ -s "${tmp}" ]; then
        if ! gcloud storage cp "${tmp}" "${PREFIX}/history.jsonl"; then
            rm -f "${tmp}"; return 1
        fi
    else
        log "history.jsonl had no valid lines this cycle; skipping its push"
    fi
    rm -f "${tmp}"
    return 0
}

# Upload .claude.json only if it is currently valid JSON (a mid-write read
# is skipped). A skipped invalid read is not a push failure.
push_claude_json() {
    local src="${USER_HOME}/.claude.json"
    [ -f "${src}" ] || return 0
    if jq -e . "${src}" >/dev/null 2>&1; then
        gcloud storage cp "${src}" "${PREFIX}/claude.json" || return 1
    else
        log ".claude.json not valid JSON this cycle; skipping its push"
    fi
    return 0
}

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

    # Manifest carries last_push_at (recency ranking for the pull) and the
    # writer identity (single-writer guard). Advance it ONLY on a fully-
    # successful cycle so it never points at a namespace whose data upload
    # failed.
    if [ "${ok}" -eq 1 ]; then
        local tmp
        tmp=$(mktemp)
        jq -n -c \
            --arg iso "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson epoch "$(date -u +%s)" \
            --arg host "${WRITER_HOST}" \
            --arg inst "${WRITER_INSTANCE}" \
            '{last_push_at: $iso, last_push_at_epoch: $epoch, writer_host: $host, writer_instance: $inst}' \
            > "${tmp}"
        gcloud storage cp "${tmp}" "${MANIFEST_PATH}" || log "manifest upload failed"
        rm -f "${tmp}"
    else
        log "push cycle incomplete; not advancing manifest"
    fi
}

# The boot pull (270_*.sh) ran moments ago, so the first periodic pull is
# one full PULL_INTERVAL away.
last_pull="$(date -u +%s)"
while true; do
    push_once
    if [ "${PULL_INTERVAL}" -gt 0 ] && [ -x "${PULL_PATH}" ] \
        && [ $(( $(date -u +%s) - last_pull )) -ge "${PULL_INTERVAL}" ]; then
        "${PULL_PATH}" || log "periodic pull exited $?"
        last_pull="$(date -u +%s)"
    fi
    sleep "${INTERVAL}"
done
LOOP_EOF
chmod 0755 "${LOOP_PATH}"

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
