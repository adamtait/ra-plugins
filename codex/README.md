# codex — OpenAI Codex CLI

Installs and configures the [OpenAI Codex](https://github.com/openai/codex) CLI, with
your choice of ChatGPT OAuth or an OpenAI API key. Auth is reconfigured on every boot,
and switching providers cleanly clears the previous one's state.

## What you get

```bash
$ codex "add tests for the auth module"    # agentic coding session in the current repo
```

Codex installs at **first boot** via OpenAI's standalone installer into
`~/.local/bin/codex`; a build-time symlink puts it on `PATH` as `codex`. Installing at
boot is what lets you pin a version through config.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins codex

# Or from a local clone:
ra plugin install ./codex
```

`ra` prompts for config and credentials, stores secrets in GCP Secret Manager, and
applies the plugin to every subsequent `ra create`. Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type   | Default  | Description                                                   |
|-----------|--------|----------|---------------------------------------------------------------|
| `enabled` | bool   | `false`  | Enable the Codex CLI.                                          |
| `release` | string | `latest` | Version to install, e.g. `0.144.1`, or `latest` for the newest. |

## Authentication

Choose one provider at install time:

| Provider | Secret / env var        | Default secret name  | How it's captured                                        |
|----------|-------------------------|----------------------|----------------------------------------------------------|
| `oauth`  | `CODEX_AUTH_JSON_B64`   | `codex-auth-json`    | Runs `codex login` locally, uploads `~/.codex/auth.json`. |
| `apikey` | `OPENAI_API_KEY`        | `openai-api-key`     | API key from platform.openai.com.                         |

ChatGPT OAuth is recommended. On every boot the plugin clears any stale credentials
from the other provider before applying the selected one, so switching providers never
leaves you silently billed against the wrong account. Rotate a credential by re-running
install with `--force`.
