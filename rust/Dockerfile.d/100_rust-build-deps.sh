#!/bin/bash
# Rust plugin — install the system packages cargo needs to build real crates.
#
# The toolchain itself is installed at first boot by rustup
# (250_rust-install.sh), but rustc does not ship a linker: it shells out to the
# system `cc`. Without build-essential even `cargo build` of hello-world fails
# at link time. pkg-config + libssl-dev cover the openssl-sys crate, which is
# pulled in transitively by most HTTP/TLS-using projects (reqwest, git2, ...).
#
# These go in at build time (not boot) because they are system packages under
# the ephemeral container root; installing them at boot would redo the work on
# every start.
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev
rm -rf /var/lib/apt/lists/*
