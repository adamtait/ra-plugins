#!/bin/bash
# Babashka plugin — install the latest bb binary at image build time.
set -euo pipefail

# Retry transient network failures (e.g. GitHub 5xx) instead of aborting the build.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

# Resolve the latest version from the github.com /releases/latest redirect
# (final URL is .../releases/tag/vX.Y.Z) rather than the rate-limited
# api.github.com endpoint. The archive filename embeds the version, so we still
# need to know it before downloading.
BB_VERSION=$(curl $CURL_RETRY -fsSL -o /dev/null -w '%{url_effective}' \
    https://github.com/babashka/babashka/releases/latest | sed 's#.*/tag/v##')
if [ -z "${BB_VERSION}" ]; then
    echo "Failed to determine latest babashka version" >&2
    exit 1
fi
BB_ARCHIVE="babashka-${BB_VERSION}-linux-amd64-static.tar.gz"
BB_URL="https://github.com/babashka/babashka/releases/download/v${BB_VERSION}/${BB_ARCHIVE}"
BB_DEST="/usr/local/bin/bb"

if [ -x "${BB_DEST}" ] && "${BB_DEST}" --version 2>/dev/null | grep -q "${BB_VERSION}"; then
    echo "babashka ${BB_VERSION} already installed, skipping."
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

curl $CURL_RETRY -fsSL "${BB_URL}" -o "${tmpdir}/${BB_ARCHIVE}"
tar -xzf "${tmpdir}/${BB_ARCHIVE}" -C "${tmpdir}"
install -m 0755 "${tmpdir}/bb" "${BB_DEST}"
bb --version
