#!/bin/bash
# Rust plugin — install configured cargo tools and put them on PATH.
#
# Runs after 250_rust-install.sh. Two parts:
#
#   1. Install (gated by a marker holding a hash of the cargo_tools list): fetch
#      cargo-binstall, then `cargo binstall` the configured crates into a
#      dedicated root, TOOLS_ROOT. binstall downloads the crate's own published
#      release binaries where they exist and otherwise compiles from source. The
#      third-party QuickInstall build service is disabled, as is telemetry. A
#      failure WARNs and lets boot continue (docs/adr/0001's warn-don't-abort
#      spirit), and the install is bounded by a timeout so a slow source build
#      can't stall the rest of the startup sequence.
#
#   2. Link (EVERY boot, not marker-gated): symlink everything in
#      TOOLS_ROOT/bin into /usr/local/bin. Because the configured tools live in
#      their own root, every binary there is one we installed — no crate->binary
#      name mapping needed. This departs from docs/adr/0002's build-time links
#      because the cargo_tools list is config, readable only at runtime; and
#      because /usr/local/bin is ephemeral the links are recreated on each start
#      (see rust/docs/adr/0001). The user's own later `cargo install`s go to
#      ~/.cargo/bin and are left to their dotfiles.
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
export RUSTUP_HOME="${USER_HOME}/.rustup"
export CARGO_HOME="${USER_HOME}/.cargo"
CARGO_BIN="${CARGO_HOME}/bin"
TOOLS_ROOT="${USER_HOME}/.local/share/ra-rust-tools"
TOOLS_MARKER="${USER_HOME}/.ra-rust-tools-installed"
# Upper bound on one boot's tool install (source builds can take minutes).
INSTALL_TIMEOUT="20m"

CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_RUST_ENABLED:-false}" = "true" ] || exit 0
[ -n "${RA_PLUGIN_RUST_CARGO_TOOLS:-}" ] || exit 0
if [ ! -x "${CARGO_BIN}/cargo" ]; then
    echo "[rust-cargo-tools] WARNING: cargo not installed; skipping cargo tools." >&2
    exit 0
fi

# string_list config arrives pipe-separated; trim stray whitespace per entry.
IFS='|' read -r -a TOOLS_RAW <<<"${RA_PLUGIN_RUST_CARGO_TOOLS}"
TOOLS=()
for t in "${TOOLS_RAW[@]}"; do
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    [ -n "${t}" ] && TOOLS+=("${t}")
done
[ "${#TOOLS[@]}" -gt 0 ] || exit 0

# Command prefix to run as the workstation user with the rustup environment —
# the same as 250_rust-install.sh's as_user, but an array so `timeout` can wrap
# it. Kept inline: plugin scripts are self-contained (repo convention).
AS_USER=(sudo -u "${USER_NAME}" env HOME="${USER_HOME}"
    RUSTUP_HOME="${RUSTUP_HOME}" CARGO_HOME="${CARGO_HOME}"
    PATH="${CARGO_BIN}:/usr/local/bin:/usr/bin:/bin")

install_binstall() {
    local arch tmpdir rc=0
    arch=$(uname -m)
    case "${arch}" in
        x86_64|aarch64) ;;
        *) echo "[rust-cargo-tools] unsupported architecture: ${arch}" >&2; return 1 ;;
    esac
    tmpdir=$(mktemp -d)
    # GitHub's releases/latest/download/ redirect avoids the rate-limited API.
    # Download to a file first so a mid-transfer retry can't corrupt the tar stream.
    curl $CURL_RETRY -fsSL \
        "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-${arch}-unknown-linux-musl.tgz" \
        -o "${tmpdir}/cargo-binstall.tgz" \
        && tar -xzf "${tmpdir}/cargo-binstall.tgz" -C "${tmpdir}" \
        && install -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
            "${tmpdir}/cargo-binstall" "${CARGO_BIN}/cargo-binstall" \
        || rc=$?
    rm -rf "${tmpdir}"
    return "${rc}"
}

# --- 1. Install ---------------------------------------------------------------
tools_hash=$(printf '%s\n' "${TOOLS[@]}" | sha256sum | cut -d' ' -f1)

# Skip only if config is unchanged AND the tools are still there — a cleaned-out
# TOOLS_ROOT/bin re-installs instead of silently staying empty. In that case
# --force is needed: binstall trusts the root's .crates.toml, which still lists
# the crates as installed.
force=()
if [ -r "${TOOLS_MARKER}" ] && [ "$(cat "${TOOLS_MARKER}")" = "${tools_hash}" ]; then
    force=(--force)
fi
if [ "${#force[@]}" -gt 0 ] && [ -n "$(ls -A "${TOOLS_ROOT}/bin" 2>/dev/null)" ]; then
    echo "[rust-cargo-tools] cargo_tools unchanged, skipping install."
elif [ -x "${CARGO_BIN}/cargo-binstall" ] || install_binstall; then
    sudo -u "${USER_NAME}" mkdir -p "${TOOLS_ROOT}"
    # binstall skips crates that are already installed at the requested version.
    if timeout "${INSTALL_TIMEOUT}" "${AS_USER[@]}" cargo binstall --no-confirm --root "${TOOLS_ROOT}" \
            --disable-strategies quick-install --disable-telemetry "${force[@]}" "${TOOLS[@]}"; then
        echo "${tools_hash}" > "${TOOLS_MARKER}"
        chown "${USER_NAME}:${USER_NAME}" "${TOOLS_MARKER}"
    else
        echo "[rust-cargo-tools] WARNING: cargo binstall failed or timed out (${INSTALL_TIMEOUT})" \
            "for some of: ${TOOLS[*]}; will retry next boot." >&2
    fi
else
    echo "[rust-cargo-tools] WARNING: could not install cargo-binstall; skipping cargo tools." >&2
fi

# --- 2. Link (every boot) -----------------------------------------------------
linked=()
for src in "${TOOLS_ROOT}/bin/"*; do
    [ -f "${src}" ] && [ -x "${src}" ] || continue
    bin=$(basename "${src}")
    dest="/usr/local/bin/${bin}"
    # Never clobber something the image provides; only (re)point our own links.
    if [ -e "${dest}" ] || [ -L "${dest}" ]; then
        if [ ! -L "${dest}" ] || [ "$(readlink "${dest}")" != "${src}" ]; then
            echo "[rust-cargo-tools] ${dest} exists and is not ours; not linking ${bin}." >&2
            continue
        fi
    fi
    ln -sf "${src}" "${dest}"
    linked+=("${bin}")
done

echo "[rust-cargo-tools] linked: ${linked[*]:-none}"
