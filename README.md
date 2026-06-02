# ra-plugins

A collection of plugins for the [`remote-agent`](https://github.com/adamtait/remote-agent) (ra) CLI — a tool for creating and managing ephemeral cloud workstations.

Each plugin is a self-contained directory with a `plugin.yaml` manifest and optional scripts that run at image build time, workstation startup, and shell login.

## Plugins

| Plugin | Description |
|--------|-------------|
| [antigravity](./antigravity/) | Installs the Antigravity (`agy`) CLI |
| [aws](./aws/) | AWS CLI v2 with credentials injected from GCP Secret Manager at boot |
| [babashka](./babashka/) | Fast-starting native Clojure interpreter (`bb`) |
| [claude](./claude/) | Claude Code — installs and configures the CLI; supports OAuth or API key |
| [claude-sync](./claude-sync/) | Syncs `~/.claude/` across workstations via a GCS bucket (see its [README](./claude-sync/README.md)) |
| [codex](./codex/) | OpenAI Codex CLI — supports ChatGPT OAuth or API key |
| [github](./github/) | GitHub CLI + PAT-based git credential helper; optionally clones repos at first boot |
| [marimo](./marimo/) | Reactive Python notebook server — auto-starts the edit server at boot |
| [terraform](./terraform/) | HashiCorp Terraform CLI |
| [tmux](./tmux/) | tmux — starts a persistent named session at boot and auto-attaches login shells |
| [uv](./uv/) | `uv` — fast Python package and project manager |

## Plugin structure

Each plugin directory may contain:

```
<plugin>/
  plugin.yaml              # manifest: name, version, description, config, auth_providers, buckets
  Dockerfile.d/            # shell scripts run during image build (sourced in filename order)
  workstation-startup.d/   # shell scripts run at workstation boot (sourced in filename order)
  profile.d/               # shell scripts sourced by every login shell
```

The `plugin.yaml` manifest declares:

- **config** — typed, documented fields the user fills in at `ra plugin install` time
- **auth_providers** — named credential bundles, each with secrets that `ra` stores in GCP Secret Manager and injects as environment variables at boot
- **buckets** — GCS buckets the plugin needs (created and IAM-bound automatically by `ra create`)

## Usage

Install a plugin into your `ra` project:

```bash
ra plugin install ./path/to/plugin
```

`ra` prompts for config values and credentials, stores secrets in GCP Secret Manager, and applies the plugin to all subsequent `ra create` calls.

See the [remote-agent docs](https://github.com/adamtait/remote-agent) for full CLI reference.
