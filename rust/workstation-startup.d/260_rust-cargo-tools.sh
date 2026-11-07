#!/bin/bash
# Rust plugin — install configured cargo tools and put them on PATH.
#
# Runs after 250_rust-install.sh. Two parts:
#
#   1. Install (gated by a marker holding a hash of the cargo_tools list): fetch
#      cargo-binstall, then `cargo binstall` the configured crates. binstall
#      downloads prebuilt binaries where the crate publishes them and falls back
#      to compiling from source otherwise. A failure WARNs and lets boot
#      continue (docs/adr/0001's warn-don't-abort spirit): a missing tool is
#      easy to fix by hand; a workstation that won't boot is not.
#
#   2. Link (EVERY boot, not marker-gated): symlink each binary the configured
#      crates installed into /usr/local/bin. This departs from docs/adr/0002's
#      build-time links because the cargo_tools list is config, readable only at
#      runtime; and because /usr/local/bin is ephemeral the links must be
#      recreated on each start (see rust/docs/adr/0001). Only binaries from
#      configured crates are linked — later manual `cargo install`s are left to
#      the user's dotfiles (put ~/.cargo/bin on PATH there).
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
export RUSTUP_HOME="${USER_HOME}/.rustup"
export CARGO_HOME="${USER_HOME}/.cargo"
CARGO_BIN="${CARGO_HOME}/bin"
TOOLS_MARKER="${USER_HOME}/.ra-rust-tools-installed"

CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_RUST_ENABLED:-false}" = "true" ] || exit 0
[ -n "${RA_PLUGIN_RUST_CARGO_TOOLS:-}" ] || exit 0
if [ ! -x "${CARGO_BIN}/cargo" ]; then
    echo "[rust-cargo-tools] WARNING: cargo not installed; skipping cargo tools." >&2
    exit 0
fi

IFS='|' read -r -a TOOLS_RAW <<<"${RA_PLUGIN_RUST_CARGO_TOOLS}"
TOOLS=()
for t in "${TOOLS_RAW[@]}"; do [ -n "${t}" ] && TOOLS+=("${t}"); done
[ "${#TOOLS[@]}" -gt 0 ] || exit 0

as_user() {
    sudo -u "${USER_NAME}" env HOME="${USER_HOME}" \
        RUSTUP_HOME="${RUSTUP_HOME}" CARGO_HOME="${CARGO_HOME}" \
        PATH="${CARGO_BIN}:/usr/local/bin:/usr/bin:/bin" "$@"
}

install_binstall() {
    local arch triple tmpdir
    arch=$(uname -m)
    case "${arch}" in
        x86_64|aarch64) triple="${arch}-unknown-linux-musl" ;;
        *) echo "[rust-cargo-tools] unsupported architecture: ${arch}" >&2; return 1 ;;
    esac
    tmpdir=$(mktemp -d)
    # GitHub's releases/latest/download/ redirect avoids the rate-limited API.
    # Download to a file first so a mid-transfer retry can't corrupt the tar stream.
    if curl $CURL_RETRY -fsSL \
        "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-${triple}.tgz" \
        -o "${tmpdir}/cargo-binstall.tgz" \
        && tar -xzf "${tmpdir}/cargo-binstall.tgz" -C "${tmpdir}" \
        && install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
            "${tmpdir}/cargo-binstall" "${CARGO_BIN}/cargo-binstall"; then
        rm -rf "${tmpdir}"
    else
        rm -rf "${tmpdir}"
        return 1
    fi
}

# --- 1. Install ---------------------------------------------------------------
tools_hash=$(printf '%s\n' "${TOOLS[@]}" | sha256sum | cut -d' ' -f1)

if [ -r "${TOOLS_MARKER}" ] && [ "$(cat "${TOOLS_MARKER}")" = "${tools_hash}" ]; then
    echo "[rust-cargo-tools] cargo_tools unchanged, skipping install."
else
    if [ -x "${CARGO_BIN}/cargo-binstall" ] || install_binstall; then
        # binstall skips crates that are already installed at the latest version.
        if as_user cargo binstall --no-confirm "${TOOLS[@]}"; then
            echo "${tools_hash}" > "${TOOLS_MARKER}"
            chown "${USER_NAME}:${USER_NAME}" "${TOOLS_MARKER}"
        else
            echo "[rust-cargo-tools] WARNING: cargo binstall failed for some of: ${TOOLS[*]}" >&2
        fi
    else
        echo "[rust-cargo-tools] WARNING: could not install cargo-binstall; skipping cargo tools." >&2
    fi
fi

# --- 2. Link (every boot) -----------------------------------------------------
# `cargo install --list` (which binstall also records into) prints:
#   cargo-edit v0.13.0:
#       cargo-add
#       cargo-upgrade
# Binary names can differ from crate names, so map crate -> binaries from it.
wanted=" ${TOOLS[*]} "
bins=$(as_user cargo install --list 2>/dev/null | awk -v wanted="${wanted}" '
    /^[^ \t]/ { crate = $1; keep = index(wanted, " " crate " ") > 0; next }
    keep && NF { print $1 }
') || bins=""

for bin in ${bins}; do
    src="${CARGO_BIN}/${bin}"
    dest="/usr/local/bin/${bin}"
    [ -x "${src}" ] || continue
    # Never clobber something the image provides; only (re)point our own links.
    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
        if [ ! -L "${dest}" ] || [[ "$(readlink "${dest}")" != "${CARGO_BIN}/"* ]]; then
            echo "[rust-cargo-tools] ${dest} exists and is not ours; not linking ${bin}." >&2
            continue
        fi
    fi
    ln -sf "${src}" "${dest}"
done

echo "[rust-cargo-tools] linked: ${bins//$'\n'/ }"
