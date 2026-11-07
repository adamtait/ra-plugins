# 1. Runtime cargo-tool symlinks and a config-hash install marker

- Status: accepted
- Applies to: the `rust` plugin

## Context

The `rust` plugin installs rustup and a toolchain at first boot into the persistent `~/.rustup`
and `~/.cargo`, like `pulumi` and `claude`. Two things are different from those plugins:

1. **Its set of executables comes from config.** The rustup proxies (`cargo`, `rustc`, …) are a
   fixed set, so they get build-time symlinks in `/usr/local/bin`, as
   [ADR 0002](../../../docs/adr/0002-plugin-clis-on-path-across-login-shells.md) prescribes.
   The binaries installed from the `cargo_tools` list are another matter. Their names come from
   `RA_PLUGIN_RUST_CARGO_TOOLS`, which only boot-time scripts can read, and a crate's binary names
   can differ from the crate name (`cargo-edit` installs `cargo-add`, `cargo-upgrade`, …). They
   can't be linked at build time.
2. **Its install has config-dependent parts.** The toolchain, components and targets can all
   change after first boot. pulumi re-checks `latest` on every boot. For Rust that means a network
   round-trip on every boot, plus a download of hundreds of MB whenever stable moves.

## Decision

- **Tool symlinks are made at boot, on every boot.** `260_rust-cargo-tools.sh` installs the
  configured crates into their own root (`~/.local/share/ra-rust-tools`), so every binary in its
  `bin/` belongs to a configured crate and nothing has to map crate names to binary names. Each
  boot runs `ln -sf` for every binary there into `/usr/local/bin`. An earlier draft parsed
  `cargo install --list` instead, which missed entries like `crate@version`. ADR 0002 warns
  that a link made at runtime vanishes when the ephemeral root resets and a marker-gated
  installer never recreates it. The link step therefore runs on every boot and is not behind
  the install marker. A file in `/usr/local/bin` the plugin
  didn't create is never overwritten.
- **Markers hold a hash of the config.** `~/.ra-rust-installed` holds a hash of the toolchain,
  components and targets. `~/.ra-rust-tools-installed` holds a hash of the `cargo_tools` list.
  If the hash matches (and, for tools, the tools root isn't empty), the install step is skipped
  and makes no network calls. A config change re-runs the install. When the toolchain is already
  installed, new components and targets go in with `rustup component add` and `rustup target add`,
  never `toolchain install`, so a floating channel is updated only when you run `rustup update`.
- **Only configured tools are linked.** Later manual `cargo install`s are not linked, so
  `~/.cargo/bin` is not effectively put on PATH. That decision stays with your dotfiles, as
  ADR 0002 says.

## Consequences

- Configured tools resolve under every shell, the same as the proxies, and with no shell config.
- Each boot runs a handful of `ln -sf`, with no cargo invocation.
- A tool dropped from `cargo_tools` stays installed and linked until it is uninstalled from the
  tools root.
- A boot never updates `stable` on its own. The README documents `rustup update`.
- Changing the toolchain leaves the previous one installed (nothing is removed). This is safe but
  can use disk space until you run `rustup toolchain uninstall`.
