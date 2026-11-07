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
  work without `sudo` and survive stop/start. The `rustup-init` binary is **SHA256-verified**.
- **On PATH in every shell.** Build-time symlinks in `/usr/local/bin` expose the rustup proxies
  (`cargo`, `rustc`, `rustdoc`, `rustfmt`, `cargo-fmt`, `cargo-clippy`, `clippy-driver`,
  `rust-analyzer`, `rust-gdb`, `rust-lldb`, `cargo-miri`, `rustup`) under bash, zsh, and
  `ra connect --command=...` alike ([ADR 0002](../docs/adr/0002-plugin-clis-on-path-across-login-shells.md)).
- **Build dependencies baked in.** `build-essential` (the `cc` linker rustc needs), `pkg-config`,
  and `libssl-dev` (for the ubiquitous `openssl-sys` crate) are installed in the image.
- **Cargo tools, prebuilt.** Crates in `cargo_tools` are installed with
  [cargo-binstall](https://github.com/cargo-bins/cargo-binstall), which downloads release binaries
  instead of compiling (falling back to a source build when none exist). Every binary they provide
  is linked into `/usr/local/bin` — e.g. `cargo-edit` gives you `cargo-add`, `cargo-upgrade`, ….

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
installed. Nothing is removed — a previous toolchain stays installed until you
`rustup toolchain uninstall` it.

## Updating

Boot does **not** auto-update a floating channel: when config is unchanged, the install step exits
without touching the network, so restarts stay fast. Update yourself:

```bash
rustup update                       # toolchains
cargo binstall cargo-nextest        # a tool (re-run to pick up a newer release)
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
- **Tool install failures don't block boot.** They log a `WARNING` and are retried on the next boot.
  Check the startup log if a tool is missing.
- **Image binaries win.** A tool binary is not linked if `/usr/local/bin` already has a file of
  that name that the plugin didn't create.

Design notes: [rust/docs/adr/](./docs/adr/).
