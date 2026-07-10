#!/bin/bash
# claude-science plugin — install Claude Science (Anthropic's AI workbench for
# scientists) at image build time.
#
# Strategy: download the published Linux x64 executable and drop it on the system
# PATH at /usr/local/bin/claude-science so every user can launch it. Upstream
# ships only a linux-x64 build, so non-x86_64 architectures are unsupported.
#
# NOTE (beta): the download URL and the fact that the artifact is a standalone
# executable (rather than a tarball/AppImage) are best-effort assumptions for the
# Claude Science beta. If upstream changes the artifact shape, only this script
# needs to change.
set -euo pipefail

# Retry transient network failures (e.g. CDN 5xx) instead of aborting the build.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

# Only linux-x64 is published upstream. Fail loudly on other arches rather than
# installing a binary that can't run.
arch=$(uname -m)
if [ "${arch}" != "x86_64" ]; then
    echo "claude-science: unsupported architecture '${arch}'; upstream ships only linux-x64" >&2
    exit 1
fi

DOWNLOAD_URL="https://downloads.claude.ai/claude-science/latest/linux-x64"
INSTALL_PATH="/usr/local/bin/claude-science"

# socat is a hard runtime dependency of the Linux sandbox networking. Without it,
# `claude-science serve` aborts at startup with
#   fatal: Error: socat is required for Linux sandbox networking ...
# and never binds its port. Install it at build time (the app suggests exactly
# this: `apt-get install socat`).
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends socat
rm -rf /var/lib/apt/lists/*

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

curl $CURL_RETRY -fsSL "${DOWNLOAD_URL}" -o "${tmpdir}/claude-science"

# install(1) sets mode + copies in one step; 0755 puts it on every user's PATH.
install -m 0755 "${tmpdir}/claude-science" "${INSTALL_PATH}"

# Best-effort verification — tolerate a beta build that lacks --version so a
# missing subcommand doesn't fail the whole image build.
"${INSTALL_PATH}" --version || echo "claude-science: --version not available (beta); continuing"
