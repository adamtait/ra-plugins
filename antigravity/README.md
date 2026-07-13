# antigravity — the Antigravity (`agy`) CLI

Installs the [Antigravity](https://antigravity.google/) agentic coding CLI (`agy`) at
image build time so it is available on every `ra` workstation.

## What you get

```bash
$ agy --version        # installed to /usr/local/bin, on PATH at boot
$ agy                  # first run starts an OAuth sign-in (prints a URL to open locally)
```

<!-- TODO: add a real task-level `agy` usage example once the CLI's command surface is confirmed. -->

The build fetches Google's official bootstrap installer, which downloads the platform
binary and verifies it with a SHA512 checksum. `agy` self-updates in the background at
runtime, so there is no version pin.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins antigravity

# Or from a local clone:
ra plugin install ./antigravity
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type | Default | Description                                   |
|-----------|------|---------|-----------------------------------------------|
| `enabled` | bool | `false` | Install the Antigravity CLI on the workstation. |

## Authentication

`agy` authenticates interactively over OAuth on first run — there is no secret to
configure in `ra`. Tokens live in the system keyring, which is empty on every freshly
created workstation, so you sign in again after each `ra create`. On an interactive
login the plugin prints a one-time hint reminding you to run `agy`.
