# et — Eternal Terminal, auto-reconnecting shells

Runs an [Eternal Terminal](https://eternalterminal.dev/) server on the workstation and
adds an `ra plugin et connect` subcommand that connects through it. Unlike plain SSH,
an Eternal Terminal session survives network drops, laptop sleeps, and IP changes —
your shell is still there when you come back.

## What you get

```bash
$ ra plugin et connect            # connect via Eternal Terminal instead of plain SSH
```

`etserver` is installed at build time (Ubuntu PPA) and starts at boot. The `connect`
command allocates local ports, brings up supervised tunnels to the workstation's SSH
and Eternal Terminal ports, waits for the server to be listening, then launches your
local `et` client. It rides the workstation's existing SSH auth — no extra secret.

## Requirements (local machine)

- The `et` client — e.g. `brew install et`.
- `python3` — used to allocate and probe local tunnel ports. It ships with macOS and
  most Linux dev machines; install it if missing (e.g. `brew install python3`).

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins et

# Or from a local clone:
ra plugin install ./et
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type | Default | Description                            |
|-----------|------|---------|----------------------------------------|
| `enabled` | bool | `false` | Install `etserver` and start it at boot. |

Exposed via `port-for-tunnel: 2022`.

## Pairs well with

[`tmux`](../tmux/) — auto-reconnect plus a persistent session means a dropped
connection drops you right back into your running work. `ra plugin et connect` opens a
real login shell, so tmux auto-attach fires automatically.
