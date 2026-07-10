# ra-plugins

A collection of plugins for the [`remote-agent`](https://github.com/adamtait/remote-agent) (`ra`) CLI — a tool for creating and managing ephemeral cloud workstations.

Each plugin is a self-contained directory with a `plugin.yaml` manifest and optional scripts that run at image build time, workstation startup, and shell login.

## Plugins

| Plugin | Description |
|--------|-------------|
| [antigravity](./antigravity/) | Installs the Antigravity (`agy`) CLI |
| [aws](./aws/) | AWS CLI v2 with credentials injected from GCP Secret Manager at boot |
| [babashka](./babashka/) | Fast-starting native Clojure interpreter (`bb`) |
| [claude](./claude/) | Claude Code — installs and configures the CLI; supports OAuth or API key |
| [claude-science](./claude-science/) | Claude Science — Anthropic's AI workbench for scientists; auto-starts the workbench server on a tunneled port (sign in via the web UI) |
| [claude-sync](./claude-sync/) | Syncs `~/.claude/` across workstations via a GCS bucket (see its [README](./claude-sync/README.md)) |
| [codex](./codex/) | OpenAI Codex CLI — supports ChatGPT OAuth or API key |
| [et](./et/) | Eternal Terminal server — auto-reconnecting connections via `ra plugin et connect` |
| [gcloud](./gcloud/) | Google Cloud CLI — authenticates via a service-account key, a Workload Identity Federation config, or the workstation's own attached identity |
| [github](./github/) | GitHub CLI + PAT-based git credential helper; optionally clones repos at first boot |
| [marimo](./marimo/) | Reactive Python notebook server — auto-starts the edit server at boot |
| [terraform](./terraform/) | HashiCorp Terraform CLI |
| [tmux](./tmux/) | tmux — starts a persistent named session at boot and auto-attaches login shells |
| [uv](./uv/) | `uv` — fast Python package and project manager |

## Usage

Install a plugin into your `ra` project:

```bash
ra plugin install ./path/to/plugin
```

`ra` prompts for config values and credentials, stores secrets in GCP Secret Manager, and applies the plugin to all subsequent `ra create` calls.

See the [remote-agent docs](https://github.com/adamtait/remote-agent) for full CLI reference.

## Creating a plugin

Want to write your own plugin? The authoring guide lives with the `ra` CLI:
**[Authoring `ra` plugins](https://github.com/adamtait/remote-agent/blob/main/docs/authoring-plugins.md)**.

It covers what makes a good plugin, where to store one for reuse, the directory
layout, the `plugin.yaml` schema, the runtime environment contract, and how to
install and test locally. The plugins in this repo are working examples to copy
from.
