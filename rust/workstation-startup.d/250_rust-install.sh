#!/bin/bash
# Rust plugin — first-boot install of rustup and the configured toolchain.
#
# Runs as part of /etc/workstation-startup.d/, after secrets/config are written
# to /run/ra/env by the core boot step. Installs rustup into the persistent
# ~/.rustup and ~/.cargo as the workstation user; 110_rust-path-link.sh baked
# the /usr/local/bin proxy symlinks pointing there.
#
# Why runtime install rather than a Dockerfile.d build install: the toolchain,
# components, and targets come from RA_PLUGIN_RUST_* config, which only runtime
# scripts can read. Installing under /home also means `rustup update` and
# `rustup target add` work without sudo and survive stop/start.
#
# Idempotency: the marker stores a hash of the toolchain/components/targets
# config. A boot with unchanged config exits without touching the network, so a
# floating channel (stable) is NOT auto-updated at boot — run `rustup update`.
# A config change re-runs the install, which adds the new toolchain/components/
# targets and switches the default (see rust/docs/adr/0001).
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
export RUSTUP_HOME="${USER_HOME}/.rustup"
export CARGO_HOME="${USER_HOME}/.cargo"
CARGO_BIN="${CARGO_HOME}/bin"
RUSTUP_BIN="${CARGO_BIN}/rustup"
INSTALL_MARKER="${USER_HOME}/.ra-rust-installed"

# Retry transient network failures (e.g. 5xx) instead of aborting the boot.
CURL_RETRY="--retry 5 --retry-connrefused --connect-timeout 30"

# Load plugin config (RA_PLUGIN_RUST_*).
[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ "${RA_PLUGIN_RUST_ENABLED:-false}" = "true" ] || exit 0

TOOLCHAIN="${RA_PLUGIN_RUST_TOOLCHAIN:-stable}"
[ -n "${TOOLCHAIN}" ] || TOOLCHAIN="stable"
# string_list config arrives pipe-separated.
IFS='|' read -r -a COMPONENTS <<<"${RA_PLUGIN_RUST_COMPONENTS:-}"
IFS='|' read -r -a TARGETS <<<"${RA_PLUGIN_RUST_TARGETS:-}"

# Run a command as the workstation user with the rustup environment. HOME is
# set explicitly because sudo's HOME handling varies across sudoers configs.
as_user() {
    sudo -u "${USER_NAME}" env HOME="${USER_HOME}" \
        RUSTUP_HOME="${RUSTUP_HOME}" CARGO_HOME="${CARGO_HOME}" \
        PATH="${CARGO_BIN}:/usr/local/bin:/usr/bin:/bin" "$@"
}

config_hash=$(printf '%s\n' "${TOOLCHAIN}" "${RA_PLUGIN_RUST_COMPONENTS:-}" \
    "${RA_PLUGIN_RUST_TARGETS:-}" | sha256sum | cut -d' ' -f1)

if [ -x "${RUSTUP_BIN}" ] && [ -r "${INSTALL_MARKER}" ] \
    && [ "$(cat "${INSTALL_MARKER}")" = "${config_hash}" ]; then
    echo "[rust-install] toolchain config unchanged, skipping."
    exit 0
fi

# 1. rustup itself (once). --default-toolchain none: the toolchain is installed
#    in step 2 so first install and later config changes share one code path.
if [ ! -x "${RUSTUP_BIN}" ]; then
    arch=$(uname -m)
    case "${arch}" in
        x86_64|aarch64) triple="${arch}-unknown-linux-gnu" ;;
        *)
            echo "[rust-install] unsupported architecture: ${arch}" >&2
            exit 1
            ;;
    esac

    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' EXIT
    url="https://static.rust-lang.org/rustup/dist/${triple}/rustup-init"
    curl $CURL_RETRY -fsSL "${url}" -o "${tmpdir}/rustup-init"
    curl $CURL_RETRY -fsSL "${url}.sha256" -o "${tmpdir}/rustup-init.sha256"
    # The .sha256 file names the path it was generated from; check against the
    # hash alone so the local filename doesn't matter.
    expected=$(cut -d' ' -f1 "${tmpdir}/rustup-init.sha256")
    echo "${expected}  ${tmpdir}/rustup-init" | sha256sum -c -
    # The user must be able to execute it out of root's 0700 mktemp dir.
    chmod 0755 "${tmpdir}" "${tmpdir}/rustup-init"

    as_user "${tmpdir}/rustup-init" -y --no-modify-path \
        --profile default --default-toolchain none
fi

# 2. The configured toolchain, components, and targets.
comp_args=(); target_args=()
for c in "${COMPONENTS[@]}"; do [ -n "${c}" ] && comp_args+=("${c}"); done
for t in "${TARGETS[@]}"; do [ -n "${t}" ] && target_args+=("${t}"); done

# If the toolchain is already installed (e.g. only components/targets changed),
# add to it with `component add` / `target add`, which never update it.
# `toolchain install` on an installed floating channel (stable) would also pull
# the newest release — an unrequested ~250 MB download and compiler change at
# boot. `toolchain list` prints full names, e.g. "stable-x86_64-unknown-linux-gnu
# (default)" or "1.84.0-x86_64-unknown-linux-gnu".
apply_toolchain() {
    if as_user "${RUSTUP_BIN}" toolchain list | grep -q "^${TOOLCHAIN}-"; then
        if [ "${#comp_args[@]}" -gt 0 ]; then
            as_user "${RUSTUP_BIN}" component add --toolchain "${TOOLCHAIN}" "${comp_args[@]}" || return 1
        fi
        if [ "${#target_args[@]}" -gt 0 ]; then
            as_user "${RUSTUP_BIN}" target add --toolchain "${TOOLCHAIN}" "${target_args[@]}" || return 1
        fi
    else
        local args=(toolchain install "${TOOLCHAIN}" --profile default)
        for c in "${comp_args[@]}"; do args+=(--component "${c}"); done
        for t in "${target_args[@]}"; do args+=(--target "${t}"); done
        as_user "${RUSTUP_BIN}" "${args[@]}" || return 1
    fi
    as_user "${RUSTUP_BIN}" default "${TOOLCHAIN}"
}

# A toolchain/component failure (typo, a nightly missing a component, network)
# WARNs and lets boot continue rather than failing the startup sequence (see
# docs/adr/0001). The marker is not written, so the next boot retries.
if ! apply_toolchain; then
    echo "[rust-install] WARNING: failed to install toolchain '${TOOLCHAIN}'" \
        "(components: ${comp_args[*]:-none}; targets: ${target_args[*]:-none}); will retry next boot." >&2
    exit 0
fi

echo "${config_hash}" > "${INSTALL_MARKER}"
chown "${USER_NAME}:${USER_NAME}" "${INSTALL_MARKER}"

as_user cargo --version
echo "[rust-install] installed toolchain ${TOOLCHAIN}"
