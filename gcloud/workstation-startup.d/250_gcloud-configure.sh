#!/bin/bash
# gcloud plugin — every-boot configuration.
#
# Runs from /etc/workstation-startup.d/, after 200_remote-agent-setup.sh has
# fetched secrets and written /run/ra/env.
#
# Two responsibilities:
#   1. Write the non-secret gcloud config (project / region / zone), overwriting
#      on every boot — same idea as the aws plugin writing ~/.aws/config.
#   2. For the service_account auth provider: decode the base64-encoded SA JSON
#      key into a file, activate it for the gcloud CLI, and export
#      GOOGLE_APPLICATION_CREDENTIALS so ADC / client libraries pick it up.
#
# The SA key is base64-encoded (env var GCLOUD_SA_KEY_B64) because
# /etc/environment and /run/ra/env can't carry multi-line values safely — the
# same reason the codex plugin base64-encodes its auth.json.
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
GCLOUD_CONFIG_DIR="${USER_HOME}/.config/gcloud"
CONFIG_FILE="${GCLOUD_CONFIG_DIR}/configurations/config_default"
KEY_FILE="${GCLOUD_CONFIG_DIR}/ra-service-account.json"

# Source fetched secrets (sets GCLOUD_SA_KEY_B64, etc.).
[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_GCLOUD_ENABLED:-false}" = "true" ] || exit 0

log() { echo "[gcloud-configure] $(date -u +%H:%M:%S) $*"; }

# Source the shared ra-env helper (ra_env_set / ra_env_unset), installed by
# 200_remote-agent-setup.sh at boot. Each updates BOTH /etc/environment and
# /run/ra/env, deduped. If the lib is somehow absent (e.g. a newer plugin
# booting against an older core that predates it), fall back to an inline copy
# with the SAME both-file contract — so behavior is identical whether or not the
# lib is present, rather than silently diverging.
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

# --- Non-secret config -------------------------------------------------------
# Read config, defaulting to empty. Validate against a conservative allow-list
# since these values get written verbatim into a config file (defense-in-depth,
# mirroring the aws plugin's region/output validation).
project="${RA_PLUGIN_GCLOUD_PROJECT:-}"
region="${RA_PLUGIN_GCLOUD_REGION:-}"
zone="${RA_PLUGIN_GCLOUD_ZONE:-}"

for pair in "project:${project}" "region:${region}" "zone:${zone}"; do
    key="${pair%%:*}"
    val="${pair#*:}"
    [[ "${val}" =~ ^[a-z0-9-]*$ ]] || { log "invalid ${key}: ${val}"; exit 1; }
done

# Create the config tree owned by the workstation user (mirrors how the github
# plugin uses `sudo -u user mkdir -p`, so the intermediate ~/.config isn't left
# root-owned). 0700 on the gcloud dir also shields the SA key file written inside
# it below — other local users can't traverse in even during the brief window
# before the key's own chmod 0600 lands.
sudo -u "${USER_NAME}" mkdir -p "${GCLOUD_CONFIG_DIR}/configurations"
chmod 0700 "${GCLOUD_CONFIG_DIR}"

# Build the INI config, emitting only the sections/keys that have a value.
{
    if [ -n "${project}" ]; then
        echo "[core]"
        echo "project = ${project}"
    fi
    if [ -n "${region}" ] || [ -n "${zone}" ]; then
        echo "[compute]"
        [ -n "${region}" ] && echo "region = ${region}"
        [ -n "${zone}" ] && echo "zone = ${zone}"
    fi
} > "${CONFIG_FILE}"

# Force "default" to be the active configuration so the file we just wrote is the
# one gcloud actually reads — a base image (or a prior boot) could otherwise
# leave active_config pointing at another named config, silently ignoring us.
echo "default" > "${GCLOUD_CONFIG_DIR}/active_config"

chmod 600 "${CONFIG_FILE}"
chown "${USER_NAME}:${USER_NAME}" "${CONFIG_FILE}" "${GCLOUD_CONFIG_DIR}/active_config"
log "wrote ${CONFIG_FILE} (project=${project:-unset}, region=${region:-unset}, zone=${zone:-unset})"

# --- Auth --------------------------------------------------------------------
_clear_stale_state() {
    # Drop any prior credential so switching keys/providers never leaves a stale
    # GOOGLE_APPLICATION_CREDENTIALS or key file behind. Clearing through the
    # helper drops the key from BOTH /etc/environment and /run/ra/env.
    ra_env_unset GOOGLE_APPLICATION_CREDENTIALS
    ra_env_unset GCLOUD_SA_KEY_B64
    rm -f "${KEY_FILE}"
}

_clear_stale_state

case "${RA_PLUGIN_GCLOUD_AUTH_PROVIDER:-}" in
    service_account)
        if [[ -z "${GCLOUD_SA_KEY_B64:-}" ]]; then
            log "GCLOUD_SA_KEY_B64 not set; auth may fail"
        elif printf '%s' "${GCLOUD_SA_KEY_B64}" | base64 -d > "${KEY_FILE}" 2>/dev/null; then
            chown "${USER_NAME}:${USER_NAME}" "${KEY_FILE}"
            chmod 0600 "${KEY_FILE}"
            log "wrote ${KEY_FILE}"

            # base64 may decode garbage successfully; verify the result parses as
            # JSON when a parser is available. Skip silently if not — the decode
            # succeeded and gcloud itself will surface bad JSON on activation.
            if command -v python3 >/dev/null 2>&1; then
                python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
                    "${KEY_FILE}" 2>/dev/null \
                    || log "warning: ${KEY_FILE} is not valid JSON; auth may fail"
            elif command -v jq >/dev/null 2>&1; then
                jq empty "${KEY_FILE}" 2>/dev/null \
                    || log "warning: ${KEY_FILE} is not valid JSON; auth may fail"
            fi

            # Activate for the gcloud CLI itself, as the workstation user and
            # pinned to this config dir (matches the repo's `sudo -u user` idiom).
            # Log a WARNING rather than aborting so a bad key doesn't take down
            # the rest of boot.
            if sudo -u "${USER_NAME}" env CLOUDSDK_CONFIG="${GCLOUD_CONFIG_DIR}" \
                gcloud auth activate-service-account \
                --key-file="${KEY_FILE}" ${project:+--project="${project}"} >/dev/null 2>&1; then
                log "activated service account for gcloud CLI"
            else
                log "WARNING: gcloud auth activate-service-account failed; auth may fail"
            fi

            # Export for ADC / client libraries (google-cloud-* SDKs).
            ra_env_set GOOGLE_APPLICATION_CREDENTIALS "${KEY_FILE}"
        else
            rm -f "${KEY_FILE}"
            log "failed to base64-decode GCLOUD_SA_KEY_B64; auth may fail"
        fi
        ;;
    "")
        log "no auth provider selected; wrote config only"
        ;;
    *)
        log "unknown auth provider '${RA_PLUGIN_GCLOUD_AUTH_PROVIDER:-}'"
        ;;
esac
