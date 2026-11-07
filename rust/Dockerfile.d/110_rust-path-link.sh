#!/bin/bash
# Rust plugin — expose the rustup proxies on PATH for every login shell.
#
# rustup is installed at first boot (250_rust-install.sh) into the persistent
# ~/.cargo/bin, not /usr/local/bin, so it is not on the default PATH. Per
# docs/adr/0002 we bake a symlink per entry point into /usr/local/bin, which is
# on the baseline PATH of every shell and invocation type.
#
# Each entry in ~/.cargo/bin is a rustup *proxy*: the same binary, which picks
# the tool to run from argv[0]. A symlink keeps argv[0] as the link's name, so
# /usr/local/bin/cargo -> ~/.cargo/bin/cargo dispatches to cargo as expected. A
# proxy whose component is not installed (e.g. rust-analyzer before it is added)
# prints rustup's own "not installed" hint, which is the behavior users expect.
#
# Why build time, and why dangling links are fine: /usr/local/bin is ephemeral
# (reset from the image on every start) while ~/.cargo lives on the persistent
# /home disk. Baked into the image, the links exist on every boot and resolve
# once the first-boot install populates ~/.cargo/bin. `-f` keeps this
# idempotent across rebuilds.
set -euo pipefail

CARGO_BIN="/home/user/.cargo/bin"

for proxy in rustup cargo rustc rustdoc rustfmt cargo-fmt cargo-clippy \
             clippy-driver rust-analyzer rust-gdb rust-gdbgui rust-lldb cargo-miri; do
    dest="/usr/local/bin/${proxy}"
    # Never replace a real binary an earlier image step installed; only (re)create
    # our own links (or links left by a previous build).
    if [ -e "${dest}" ] && [ ! -L "${dest}" ]; then
        echo "rust plugin: ${dest} exists and is not a symlink; not linking ${proxy}." >&2
        continue
    fi
    ln -sf "${CARGO_BIN}/${proxy}" "${dest}"
done
