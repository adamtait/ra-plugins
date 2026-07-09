#!/bin/bash
# claude-science plugin — start the Claude Science workbench server at boot.
#
# Runs as root from /etc/workstation-startup.d/, after 200_remote-agent-setup.sh
# has sourced secrets/config into /run/ra/env and 250_claude-science-setup.sh has
# exported the OAuth token. Drops privileges to the workstation user and detaches
# the server with setsid so it survives the startup script's exit.
#
# Idempotency: pgrep on the server command line — running the script twice on the
# same boot is a no-op on the second run.
#
# Logging: appends to ~/.claude-science.log (no rotation; acceptable for a
# single-user workstation).
#
# NOTE (beta): the launch subcommand/flags below are a best-effort assumption for
# the Claude Science beta. Confirm the real invocation with `claude-science --help`
# on a running workstation; this launch line is the only thing that changes if the
# CLI differs.
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
LOG_FILE="${USER_HOME}/.claude-science.log"

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SCIENCE_ENABLED:-false}" = "true" ] || exit 0

port="${RA_PLUGIN_CLAUDE_SCIENCE_PORT_FOR_TUNNEL:-2719}"
working_directory="${RA_PLUGIN_CLAUDE_SCIENCE_WORKING_DIRECTORY:-}"

# Validate port is a positive integer in the legal TCP range. The plugin schema
# declares port-for-tunnel as an int, but RA_PLUGIN_* values are unquoted env
# strings and nothing on the workstation side re-checks them.
if [[ ! "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    echo "[claude-science-start] invalid port '${port}'; must be 1-65535" >&2
    exit 1
fi

# Resolve working directory: blank → $USER_HOME (matches marimo/tmux idiom).
# `~` expands to root's home in a root-run script, so expand it manually against
# $USER_HOME.
if [[ -z "${working_directory}" ]]; then
    working_directory="${USER_HOME}"
else
    working_directory="${working_directory/#\~/${USER_HOME}}"
fi

# Create the directory as the workstation user so it ends up user-owned (mkdir as
# root would leave it root:root and unwritable by the user).
if [[ ! -d "${working_directory}" ]]; then
    if ! sudo -u "${USER_NAME}" mkdir -p "${working_directory}" 2>/dev/null; then
        echo "[claude-science-start] warning: could not create '${working_directory}'; falling back to home." >&2
        working_directory="${USER_HOME}"
    fi
fi

# Idempotency: a previous boot (or a previous run of this script) may have left
# the server running. The "serve" anchor avoids false matches on unrelated
# commands that happen to contain "claude-science". NOTE: this anchor must stay
# in sync with the launch subcommand at the bottom of this script — if the real
# beta CLI verb differs from "serve", update BOTH or dedup silently breaks.
if pgrep -u "${USER_NAME}" -f "claude-science serve" >/dev/null 2>&1; then
    echo "[claude-science-start] claude-science already running; skipping."
    exit 0
fi

# Port collision pre-check — without this, the server bind-fails silently into the
# log and the user sees an unreachable port with no obvious cause.
if command -v ss >/dev/null 2>&1 && ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
    echo "[claude-science-start] port ${port} already in use; aborting." >&2
    exit 1
fi

# Launch detached:
#   - setsid --fork puts the server in its own session/process-group so it
#     survives this script's exit and is immune to any SIGHUP from teardown.
#   - env HOME=... PATH=... — /etc/workstation-startup.d/ runs with a near-empty
#     environment; without HOME the server writes config/state under / or /root.
#     CLAUDE_CODE_OAUTH_TOKEN is passed through explicitly so the server inherits
#     the auth token exported by 250_claude-science-setup.sh.
#   - exec claude-science replaces bash so there's no extra shell PID in pgrep.
#   - </dev/null detaches stdin so the daemon has no controlling tty.
sudo -u "${USER_NAME}" \
    env HOME="${USER_HOME}" PATH="/usr/local/bin:/usr/bin:/bin" \
    CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    setsid --fork bash -c \
    "cd '${working_directory}' && exec claude-science serve --headless --host 0.0.0.0 --port ${port} >> '${LOG_FILE}' 2>&1" \
    </dev/null

echo "[claude-science-start] started claude-science on port ${port} in ${working_directory}"
