#!/bin/bash
# uv plugin — install uv and uvx at image build time.
set -euo pipefail

if [ -x /usr/local/bin/uv ]; then
    echo "uv already installed, skipping."
    exit 0
fi

# Retry transient network failures (e.g. GitHub 5xx) instead of aborting the build.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

arch=$(uname -m)
case "${arch}" in
    x86_64)  uv_arch="x86_64-unknown-linux-gnu" ;;
    aarch64) uv_arch="aarch64-unknown-linux-gnu" ;;
    *)
        echo "Unsupported architecture: ${arch}" >&2
        exit 1
        ;;
esac

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# GitHub's releases/latest/download/ redirect resolves "latest" via the release
# CDN, avoiding the rate-limited api.github.com endpoint entirely.
curl $CURL_RETRY -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${uv_arch}.tar.gz" \
    | tar -xz -C "${tmpdir}"
install -m 0755 "${tmpdir}/uv-${uv_arch}/uv"  /usr/local/bin/uv
install -m 0755 "${tmpdir}/uv-${uv_arch}/uvx" /usr/local/bin/uvx

uv --version
