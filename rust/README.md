# rust — the Rust toolchain on every workstation

Installs Rust via [rustup](https://rustup.rs/) — `cargo`, `rustc`, `rustfmt`, `clippy`, and
any extra components, targets, and cargo tools you configure — so a new `ra` workstation can
build Rust projects the moment you connect.

## What you get

```bash
$ cargo new hello && cd hello && cargo run    # build and run
$ cargo clippy && cargo fmt                   # lint and format (default profile)
$ cargo nextest run                           # if cargo-nextest is in cargo_tools
```

- **Toolchain at first boot.** rustup installs into `~/.rustup` and `~/.cargo` on the persistent
  `/home` disk, owned by you, so `rustup update`, `rustup target add`, and `rustup toolchain install`
  work without `sudo` and survive stop/start. The `rustup-init` binary is **SHA256-verified**
  (cargo-binstall, below, is not — see Caveats).
- **On PATH in every shell.** Build-time symlinks in `/usr/local/bin` expose the rustup proxies
  (`cargo`, `rustc`, `rustdoc`, `rustfmt`, `cargo-fmt`, `cargo-clippy`, `clippy-driver`,
  `rust-analyzer`, `rust-gdb`, `rust-lldb`, `cargo-miri`, `rustup`) under bash, zsh, and
  `ra connect --command=...` alike ([ADR 0002](../docs/adr/0002-plugin-clis-on-path-across-login-shells.md)).
- **Build dependencies baked in.** `build-essential` (the `cc` linker rustc needs), `pkg-config`,
  and `libssl-dev` (for the ubiquitous `openssl-sys` crate) are installed in the image.
- **Cargo tools, prebuilt.** Crates in `cargo_tools` are installed with
  [cargo-binstall](https://github.com/cargo-bins/cargo-binstall) into their own root,
  `~/.local/share/ra-rust-tools`. binstall downloads the crate's own published release binaries
  and falls back to a source build when there are none; the third-party QuickInstall build service
  and binstall telemetry are disabled. Every binary they provide is linked into `/usr/local/bin` —
  e.g. `cargo-edit` gives you `cargo-add`, `cargo-upgrade`, …. Entries may pin a version
  (`cargo-nextest@0.9.80`).

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins rust

# Or from a local clone:
ra plugin install ./rust
```

`ra` prompts for config and applies the plugin to every subsequent `ra create`. Set `enabled` to
`true` when prompted.

## Configuration

| Field         | Type        | Default  | Description |
|---------------|-------------|----------|-------------|
| `enabled`     | bool        | `false`  | Install the Rust toolchain. |
| `toolchain`   | string      | `stable` | Default toolchain: `stable`, `beta`, `nightly`, a version (`1.84.0`), or a dated nightly (`nightly-2026-10-01`). |
| `components`  | string_list | —        | Extra components beyond the `default` profile (which already has `rustfmt` and `clippy`), e.g. `rust-analyzer`, `rust-src`, `llvm-tools`. |
| `targets`     | string_list | —        | Extra compilation targets, e.g. `wasm32-unknown-unknown`, `x86_64-unknown-linux-musl`. |
| `cargo_tools` | string_list | —        | Crate names to install as tools, e.g. `cargo-nextest`, `cargo-watch`, `cargo-edit`. |

Changing any of these and recreating (or restarting) the workstation applies the change on the
next boot: a new toolchain/component/target is installed and made the default; new tools are
installed. Adding a component or target to an already-installed toolchain does **not** update it.
Nothing is removed — a tool dropped from `cargo_tools` stays installed and on PATH until you
`cargo uninstall --root ~/.local/share/ra-rust-tools <crate>`, and — a previous toolchain stays installed until you
`rustup toolchain uninstall` it.

## Updating

Boot does **not** auto-update a floating channel: when config is unchanged, the install step exits
without touching the network, so restarts stay fast. Update yourself:

```bash
rustup update                                                          # toolchains
cargo binstall --root ~/.local/share/ra-rust-tools --force cargo-nextest  # a configured tool
```

## PATH and `cargo install`

Only the rustup proxies and binaries from **configured** `cargo_tools` are on `PATH`. Anything you
`cargo install` (or `cargo binstall`) yourself later lands in `~/.cargo/bin`, which is not on
`PATH` by default. If you want it there, add it in your shell dotfiles, e.g. a zsh `conf.d` file:

```zsh
path=("$HOME/.cargo/bin" $path)
```

(`cargo <subcommand>` tools still work without this — cargo searches `~/.cargo/bin` itself.)

## Caveats

- **Nightly component gaps.** Some nightlies ship without a component (historically `clippy`,
  `rust-analyzer`, `miri`). If install fails on a nightly, pin a dated nightly that has them.
- **First boot takes longer** — roughly a minute or two for the toolchain, plus any `cargo_tools`
  that have no prebuilt binary and must compile.
- **Install failures don't block boot.** A toolchain/component failure (e.g. a typo'd component)
  or a tool failure logs a `WARNING` and is retried on the next boot; the tool install is capped at
  20 minutes per boot. Check the startup log if something is missing.
- **Image binaries win.** A proxy or tool is not linked if `/usr/local/bin` already has a real file
  of that name that the plugin didn't create.
- **cargo-binstall is unverified.** It tracks the latest GitHub release with no checksum check
  (like the `uv` plugin). The tools it installs come from each crate's own GitHub releases (or are
  built from crates.io source).

Design notes: [rust/docs/adr/](./docs/adr/).
