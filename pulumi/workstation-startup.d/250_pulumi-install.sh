#!/bin/bash
# Pulumi plugin — first-boot install of the Pulumi CLI into the persistent $HOME.
#
# Runs as part of /etc/workstation-startup.d/, after secrets are written by
# 200_remote-agent-setup.sh. Installs into ~/.pulumi/bin (under the persistent
# /home disk); 100_pulumi-path-link.sh baked the /usr/local/bin/pulumi symlink
# pointing there. Bails fast on later boots once the desired version is present.
#
# Why runtime install rather than a Dockerfile.d build install (as terraform
# does): the version to install comes from the RA_PLUGIN_PULUMI_RELEASE config,
# which is only available to runtime scripts (via /run/ra/env), never at image
# build time. Honoring the pin therefore requires a first-boot install.
#
# The Pulumi Cloud access token (PULUMI_ACCESS_TOKEN), if configured, is written
# to /etc/environment by the core secret mechanism — no work needed here.
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
PULUMI_HOME="${USER_HOME}/.pulumi"
PULUMI_BIN_DIR="${PULUMI_HOME}/bin"
PULUMI_BIN="${PULUMI_BIN_DIR}/pulumi"

# Retry transient network failures (e.g. 5xx) instead of aborting the boot.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

# Load plugin config (RA_PLUGIN_PULUMI_*).
[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_PULUMI_ENABLED:-false}" = "true" ] || exit 0

# Resolve the target version. 'latest' (the config default, and the fallback if
# unset) queries Pulumi's version endpoint, which — unlike the GitHub releases
# API — is not rate limited. A pinned value may be given with or without a
# leading 'v'; normalize it off.
release="${RA_PLUGIN_PULUMI_RELEASE:-latest}"
if [ -z "${release}" ] || [ "${release}" = "latest" ]; then
    VERSION=$(curl $CURL_RETRY -fsSL https://www.pulumi.com/latest-version)
else
    VERSION="${release#v}"
fi

if [ -z "${VERSION}" ]; then
    echo "[pulumi-install] failed to determine Pulumi version to install" >&2
    exit 1
fi

# Fast path / idempotency, keyed on the installed version. A pinned version thus
# installs once and stays put; 'latest' reinstalls only when a newer release
# appears. `pulumi version` prints e.g. "v3.252.0".
if [ -x "${PULUMI_BIN}" ] && "${PULUMI_BIN}" version 2>/dev/null | grep -qx "v${VERSION}"; then
    echo "[pulumi-install] pulumi v${VERSION} already installed, skipping."
    exit 0
fi

# Pulumi's release assets use x64/arm64, not amd64.
arch=$(uname -m)
case "${arch}" in
    x86_64)  pulumi_arch="x64" ;;
    aarch64) pulumi_arch="arm64" ;;
    *)
        echo "[pulumi-install] unsupported architecture: ${arch}" >&2
        exit 1
        ;;
esac

ARCHIVE="pulumi-v${VERSION}-linux-${pulumi_arch}.tar.gz"
BASE="https://github.com/pulumi/pulumi/releases/download/v${VERSION}"
ARCHIVE_URL="${BASE}/${ARCHIVE}"
# Note: the checksums filename carries NO leading 'v' on the version.
SUMS_URL="${BASE}/pulumi-${VERSION}-checksums.txt"

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

curl $CURL_RETRY -fsSL "${ARCHIVE_URL}" -o "${tmpdir}/${ARCHIVE}"
curl $CURL_RETRY -fsSL "${SUMS_URL}" -o "${tmpdir}/checksums.txt"

# Verify the archive against Pulumi's published SHA256 checksum. Filter the
# checksums file to just our archive so sha256sum -c doesn't choke on the other
# platform entries that aren't present locally.
expected_line=$(grep " ${ARCHIVE}\$" "${tmpdir}/checksums.txt" || true)
if [ -z "${expected_line}" ]; then
    echo "[pulumi-install] no checksum entry for ${ARCHIVE}" >&2
    exit 1
fi
(cd "${tmpdir}" && echo "${expected_line}" | sha256sum -c -)

# The tarball's top level is pulumi/<binaries> (pulumi + language/resource hosts).
tar -xzf "${tmpdir}/${ARCHIVE}" -C "${tmpdir}"

# Install the binaries into ~/.pulumi/bin (install(1) replaces each in place).
mkdir -p "${PULUMI_BIN_DIR}"
install -m 0755 "${tmpdir}/pulumi/"* "${PULUMI_BIN_DIR}/"
chown -R "${USER_NAME}:${USER_NAME}" "${PULUMI_HOME}"

# Confirm as the user (this is what the /usr/local/bin/pulumi symlink resolves to).
sudo -u "${USER_NAME}" "${PULUMI_BIN}" version
echo "[pulumi-install] installed pulumi v${VERSION} into ${PULUMI_BIN_DIR}"
