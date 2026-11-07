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

# 2. The configured toolchain, components, and targets. Idempotent: rustup
#    skips anything already present.
install_args=(toolchain install "${TOOLCHAIN}" --profile default)
for c in "${COMPONENTS[@]}"; do [ -n "${c}" ] && install_args+=(--component "${c}"); done
for t in "${TARGETS[@]}"; do [ -n "${t}" ] && install_args+=(--target "${t}"); done

as_user "${RUSTUP_BIN}" "${install_args[@]}"
as_user "${RUSTUP_BIN}" default "${TOOLCHAIN}"

echo "${config_hash}" > "${INSTALL_MARKER}"
chown "${USER_NAME}:${USER_NAME}" "${INSTALL_MARKER}"

as_user cargo --version
echo "[rust-install] installed toolchain ${TOOLCHAIN}"
