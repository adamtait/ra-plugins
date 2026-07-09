#!/bin/bash
# claude-science plugin — every-boot auth configuration.
#
# Runs from /etc/workstation-startup.d/, after 200_remote-agent-setup.sh has
# fetched secrets and written /run/ra/env, and before 255_claude-science-start.sh
# starts the workbench server. Exports the Claude subscription OAuth token into
# the persistent environment so the server (and login shells) can authenticate.
#
# NOTE (beta): we assume Claude Science reads CLAUDE_CODE_OAUTH_TOKEN from the
# environment (the same token Claude Code uses). If the app expects a different
# mechanism, adjust the export / add config-file seeding here.
set -euo pipefail

# Source fetched secrets (sets CLAUDE_CODE_OAUTH_TOKEN, etc.).
[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_CLAUDE_SCIENCE_ENABLED:-false}" = "true" ] || exit 0

log() { echo "[claude-science-setup] $(date -u +%H:%M:%S) $*"; }

# Source the shared ra-env helper (ra_env_set / ra_env_unset), installed by
# 200_remote-agent-setup.sh at boot. Each updates BOTH /etc/environment and
# /run/ra/env, deduped. If the lib is somehow absent (e.g. a newer plugin booting
# against an older core that predates it), fall back to an inline copy with the
# SAME both-file contract — so behavior is identical whether or not the lib is
# present, rather than silently diverging.
if [ -r /usr/local/lib/ra/ra-env.sh ]; then
    # shellcheck source=/dev/null
    . /usr/local/lib/ra/ra-env.sh
else
    log "WARNING: /usr/local/lib/ra/ra-env.sh missing; using inline fallback"
    : "${RA_ENV_FILE:=/run/ra/env}"
    ra_env_set() {
        local key="$1" val="$2"
        local quoted="${val//\'/\'\\\'\'}"
        [ -f /etc/environment ] || : > /etc/environment
        sed -i "/^${key}=/d" /etc/environment
        printf "%s='%s'\n" "${key}" "${quoted}" >> /etc/environment
        if [ ! -f "${RA_ENV_FILE}" ]; then
            ( umask 077; : > "${RA_ENV_FILE}" )
            chown user:user "${RA_ENV_FILE}"
            chmod 0600 "${RA_ENV_FILE}"
        fi
        sed -i "/^${key}=/d" "${RA_ENV_FILE}"
        printf "%s='%s'\n" "${key}" "${quoted}" >> "${RA_ENV_FILE}"
    }
    ra_env_unset() {
        local key="$1"
        [ -f /etc/environment ] && sed -i "/^${key}=/d" /etc/environment
        [ -f "${RA_ENV_FILE}" ] && sed -i "/^${key}=/d" "${RA_ENV_FILE}"
        return 0
    }
fi

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "CLAUDE_CODE_OAUTH_TOKEN not set; the workbench server may fail to authenticate"
else
    ra_env_set CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN}"
    log "exported CLAUDE_CODE_OAUTH_TOKEN"
fi
