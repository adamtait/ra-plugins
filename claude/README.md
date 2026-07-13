# claude — Claude Code, installed and authenticated

Installs [Claude Code](https://www.claude.com/product/claude-code), Anthropic's agentic
coding CLI, and configures auth on every boot from your choice of an OAuth token or an
API key. Switching providers cleanly clears the previous one's state.

## What you get

```bash
$ claude "explain this repo"          # interactive session in the current directory
$ claude -p "respond with OK"         # non-interactive, prints and exits
```

Node.js 20 is installed at build time; Claude Code itself installs on **first boot** via
`npm install -g @anthropic-ai/claude-code` into `~/.npm-global` (persistent `/home`
disk), reachable on `PATH` as `claude` through a build-time symlink. After auth is
configured, the plugin runs a one-line smoke test to confirm the CLI responds.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins claude

# Or from a local clone:
ra plugin install ./claude
```

`ra` prompts for config and credentials, stores secrets in GCP Secret Manager, and
applies the plugin to every subsequent `ra create`. Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type | Default | Description         |
|-----------|------|---------|---------------------|
| `enabled` | bool | `false` | Enable Claude Code. |

## Authentication

Choose one provider at install time:

| Provider | Secret / env var           | Default secret name        | Source                     |
|----------|----------------------------|----------------------------|----------------------------|
| `oauth`  | `CLAUDE_CODE_OAUTH_TOKEN`  | `claude-code-oauth-token`  | claude.ai/settings         |
| `apikey` | `ANTHROPIC_API_KEY`        | `anthropic-api-key`        | console.anthropic.com      |

OAuth is recommended. In `apikey` mode the key is delivered through a helper script
rather than persisted in the environment. Rotate a credential by re-running install
with `--force`.

## Pairs well with

[`claude-sync`](../claude-sync/) syncs `~/.claude/` (session transcripts, todos, plans,
history) across your workstations. Install both together so your Claude Code state
follows you from one `ra` workstation to the next.
