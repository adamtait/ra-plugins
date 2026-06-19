#!/bin/bash
# Claude plugin — install Node.js 20 at image build time.
# Required because Claude Code is distributed as an npm package.
set -euo pipefail

# Retry transient network failures (e.g. 5xx) instead of aborting the build.
curl --retry 5 --retry-connrefused --connect-timeout 30 -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*
