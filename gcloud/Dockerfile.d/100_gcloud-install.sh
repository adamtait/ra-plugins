#!/bin/bash
# gcloud plugin — install the Google Cloud CLI at image build time.
# Always installs the latest release from the "rapid" channel; no version is
# pinned by design. gcloud is often already present in the base image, in which
# case this is a no-op.
set -euo pipefail

if command -v gcloud >/dev/null 2>&1; then
    echo "Google Cloud CLI already installed, skipping."
    exit 0
fi

# Retry transient network failures (e.g. 5xx) instead of aborting the build.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

arch=$(uname -m)
case "${arch}" in
    x86_64)  gcloud_arch="x86_64" ;;
    aarch64) gcloud_arch="arm" ;;
    *)
        echo "Unsupported architecture: ${arch}" >&2
        exit 1
        ;;
esac

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# Download to a temp file first — never pipe `curl --retry` straight into tar,
# because a mid-transfer retry re-emits from byte 0 and corrupts the stream.
curl $CURL_RETRY -fsSL \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${gcloud_arch}.tar.gz" \
    -o "${tmpdir}/google-cloud-cli.tar.gz"

tar -C /usr/local -xzf "${tmpdir}/google-cloud-cli.tar.gz"

/usr/local/google-cloud-sdk/install.sh \
    --quiet \
    --usage-reporting false \
    --path-update false \
    --command-completion false

# Expose the CLIs on the default PATH (matches how aws installs to /usr/local/bin).
for bin in gcloud gsutil bq; do
    ln -sf "/usr/local/google-cloud-sdk/bin/${bin}" "/usr/local/bin/${bin}"
done

gcloud --version
