# tmux — a persistent session your shells auto-attach to

Installs [tmux](https://github.com/tmux/tmux), starts a named session at boot, and
auto-attaches every interactive login to it — so a dropped SSH connection, an `ra
connect`, or an `ra plugin et connect` all drop you straight back into the same running
session with your work intact.

## What you get

```bash
$ ra connect my-workstation      # login auto-attaches to the "main" session
$ tmux ls                         # main: 1 windows (created ...) (attached)
```

The session starts at boot (as your user), and login shells attach to it automatically
on both `ra connect` and `ra plugin et connect` — no `connect.login_command` needed.
Panes spawn as login shells, so `/etc/profile.d/*` and injected secrets load in each
one. The server is configured to survive going to zero sessions.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins tmux

# Or from a local clone:
ra plugin install ./tmux
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field             | Type   | Default | Description                                          |
|-------------------|--------|---------|------------------------------------------------------|
| `enabled`         | bool   | `false` | Enable the tmux plugin.                              |
| `session_name`    | string | `main`  | Name of the persistent session.                      |
| `start_directory` | string | `~`     | Working directory for the session (blank = home dir).|

## Pairs well with

[`et`](../et/) — Eternal Terminal reconnects a dropped connection automatically, and
tmux auto-attach means you land right back in your session when it does.
