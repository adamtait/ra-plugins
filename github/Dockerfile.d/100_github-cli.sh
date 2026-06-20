#!/bin/bash
# GitHub plugin — install the GitHub CLI (`gh`) at image build time.
# Equivalent to the block previously hardcoded in the core ra Dockerfile.
set -euo pipefail

# Write straight to the destination with -o (not `| dd`): piping `curl --retry`
# would re-emit from byte 0 on a mid-transfer retry, corrupting the keyring. With
# -o, the retry re-downloads cleanly and overwrites the file each attempt.
# Retry transient network failures (e.g. 5xx) instead of aborting the build.
curl --retry 5 --retry-connrefused --connect-timeout 30 -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh
rm -rf /var/lib/apt/lists/*
