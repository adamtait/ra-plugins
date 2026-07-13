# marimo — a reactive Python notebook, running at boot

Installs [marimo](https://marimo.io/) and auto-starts its edit server on the
workstation. marimo notebooks are reactive (change a cell, dependents re-run) and are
stored as plain `.py` files. You reach the editor through an `ra` port tunnel — the
server binds loopback only and is never exposed on the network.

## What you get

```bash
$ ra tunnel 2718:2718 <workstation>     # forward the edit server to your machine
# then open http://localhost:2718 in your browser
```

marimo is installed at build time (via `uv`), and its edit server starts at boot on
`127.0.0.1:2718`. Because it binds loopback and is reached only through the tunnel, it
runs with `--no-token`. Notebooks are read from / created in the configured
`working_directory` (your home directory by default).

> **Security:** the edit server has no auth token. That is safe *only* because it binds
> `127.0.0.1` on a single-user workstation and is reachable solely through the port
> tunnel. Do not expose port `2718` directly to an untrusted network.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins marimo

# Or from a local clone:
ra plugin install ./marimo
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field               | Type   | Default | Description                                                    |
|---------------------|--------|---------|----------------------------------------------------------------|
| `enabled`           | bool   | `false` | Install marimo and auto-start the edit server.                 |
| `working_directory` | string | `""`    | Where marimo looks for / creates notebooks (blank = home dir). |

Exposed via `port-for-tunnel: 2718`.
