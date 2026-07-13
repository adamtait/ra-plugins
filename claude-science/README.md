# claude-science — Anthropic's AI workbench for scientists

Installs [Claude Science](https://claude.ai/) and auto-starts its headless workbench
server on the workstation. You reach the web UI through an `ra` port tunnel; the server
binds loopback only and is never exposed on the network.

## What you get

```bash
$ ra tunnel 2719              # forward the workbench server to your machine
# then open http://localhost:2719 and sign in through the web UI

$ ra tunnel 2720              # (second terminal) forward the sandbox-content port
                              # so HTML previews Claude generates render
```

The workbench binary is installed at build time; the server starts at boot on
`127.0.0.1:2719` (loopback) via `claude-science serve --no-browser`. The sandbox
content port (`2720`) is **not** auto-tunneled — forward it yourself when you need
HTML previews.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins claude-science

# Or from a local clone:
ra plugin install ./claude-science
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field               | Type   | Default | Description                                                       |
|---------------------|--------|---------|-------------------------------------------------------------------|
| `enabled`           | bool   | `false` | Install Claude Science and auto-start the workbench server.       |
| `working_directory` | string | `""`    | Where Claude Science stores projects (blank = home dir).          |

Exposed via `port-for-tunnel: 2719`.

## Authentication

Sign in once through the tunneled web UI — this requires a Pro, Max, Team, or
Enterprise plan. Auth persists under `~/.claude-science/`; since workstation home is
not persisted by default, you sign in again on each freshly created workstation.

> Claude Science is a beta product; the install downloads the latest Linux x64 build
> and is x86_64-only.
