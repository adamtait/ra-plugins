# ra-plugins

**Add a tool — and its credentials — to every `ra` cloud workstation with one command.**

Plugins for [`remote-agent`](https://github.com/adamtait/remote-agent) (`ra`), the CLI that runs your
coding agents on disposable [Google Cloud Workstations](https://cloud.google.com/workstations) instead
of your laptop. `ra` ships with no built-in tooling — each plugin here is a self-contained directory
that installs a CLI, pulls its credentials from GCP Secret Manager at boot, and (for server tools)
starts the process for you.

```console
$ ra plugin install https://github.com/adamtait/ra-plugins github
Enable GitHub plugin? [Y/n] y
Git repositories to clone into ~/workspace on first boot (one per line, blank to finish):
  git@github.com:me/api.git
GitHub Personal Access Token: ****************
# → PAT stored in GCP Secret Manager; only its name is written to your ra config

$ ra create
# → new workstation boots with `gh` installed, the PAT wired into git's credential
#   helper, and me/api.git already cloned to ~/workspace/api
```

## Why plugins?

- **A directory, not a package.** Each plugin is a `plugin.yaml` manifest plus scripts that run at
  image build, workstation boot, and shell login. `ra plugin install` copies them into your config —
  no package manager, no lockfile, and no runtime dependency back on this repo.
- **Secrets by name, never in the image.** You paste a token once at install; `ra` stores the *value*
  in GCP Secret Manager and keeps only its *name* in config, which the workstation's own service
  account resolves at boot. Nothing sensitive is committed or baked into the Docker image.
- **Off by default, enabled on purpose.** Plugins self-gate on `RA_PLUGIN_<NAME>_ENABLED`, so a plugin
  changes a workstation only once you set `enabled` at install time. (`github` is the one exception —
  it defaults to on.)
- **Auth your way.** Plugins that need credentials offer a choice of providers: `claude` and `codex`
  take an OAuth login or an API key; `gcloud` takes a service-account key, a Workload Identity config,
  *or* the workstation's own attached identity; `aws` takes access keys.
- **Servers that start themselves.** `marimo`, `claude-science`, and `et` launch their process at boot
  and expose it over a private port tunnel (`ra tunnel <port>`) — nothing is bound to the public
  network.

## Plugins

| Plugin | Adds |
|--------|------|
| [antigravity](./antigravity/) | The Antigravity (`agy`) coding CLI |
| [aws](./aws/) | AWS CLI v2, with access keys injected from Secret Manager at boot |
| [babashka](./babashka/) | `bb` — a fast-starting native Clojure interpreter |
| [claude](./claude/) | Claude Code, authed by OAuth token or API key |
| [claude-science](./claude-science/) | Anthropic's AI workbench for scientists; auto-starts the server on a tunneled port |
| [claude-sync](./claude-sync/) | Syncs `~/.claude/` across workstations via a GCS bucket |
| [codex](./codex/) | OpenAI Codex CLI, authed by ChatGPT OAuth or API key |
| [et](./et/) | Eternal Terminal — `ra plugin et connect` for a shell that auto-resumes after a drop |
| [gcloud](./gcloud/) | Google Cloud CLI (service-account key, Workload Identity, or attached identity) |
| [github](./github/) | GitHub CLI + PAT git credential helper; optional repo auto-clone |
| [marimo](./marimo/) | Reactive Python notebook server, auto-started at boot |
| [pulumi](./pulumi/) | Pulumi IaC CLI; optional Pulumi Cloud login via access token |
| [terraform](./terraform/) | HashiCorp Terraform CLI |
| [tmux](./tmux/) | tmux — a persistent named session at boot, auto-attached on login |
| [uv](./uv/) | `uv` — a fast Python package and project manager |

Each plugin has its own README with install, configuration, and auth details.

## Install

Plugins install into an existing `ra` project, so install [`ra`](https://github.com/adamtait/remote-agent)
first. The general form is `ra plugin install <source> [<plugin>]`:

```bash
# One plugin by name from this multi-plugin repo:
ra plugin install https://github.com/adamtait/ra-plugins claude

# From a local clone (handy while developing a plugin):
ra plugin install ./claude

# Pin a branch, tag, or commit:
ra plugin install https://github.com/adamtait/ra-plugins codex --ref main

# Choose where it applies — --user (all your projects) or --local (this project):
ra plugin install https://github.com/adamtait/ra-plugins tmux --user
```

`--user` writes to `~/.config/ra/` (a baseline for every project); `--local` writes to `.ra/` in the
current project and overrides the user level. `ra plugin list` shows what's installed and at which level.

## Usage

`ra plugin install` prompts for each config field, the auth provider, and any secrets (hidden input),
then every subsequent `ra create` bakes the plugin in. Install several, provision once:

```bash
ra plugin install https://github.com/adamtait/ra-plugins claude   # agent + credential helper
ra plugin install https://github.com/adamtait/ra-plugins tmux     # persistent session
ra create                                                         # boots with both
```

Rotate a credential by re-running the install with `--force` to capture a new secret version.
Per-operation helpers (like the GitHub PAT) pick it up with no restart:

```bash
ra plugin install https://github.com/adamtait/ra-plugins github --force
```

Reach a server plugin's port from your machine (e.g. marimo's notebook UI on `2718`):

```bash
ra tunnel 2718        # forward the workstation port to localhost:2718
```

## Configuration

Each plugin declares its own config in `plugin.yaml` and prompts for it at install time. Two things
hold across all of them:

- **Config vs. secrets.** Config field *values* are stored in your `ra` config; secret *values* go to
  GCP Secret Manager and only their *names* are kept in config. See
  [Auth & Security](https://github.com/adamtait/remote-agent/blob/main/docs/auth_and_security.md).
- **`enabled`.** Most plugins default to `enabled: false` — say yes at install to turn them on.

Plugins with richer options document them in their own directory — see
[`claude-sync`](./claude-sync/README.md) for a worked example.

## Creating a plugin

The authoring guide lives with the `ra` CLI:
**[Authoring `ra` plugins](https://github.com/adamtait/remote-agent/blob/main/docs/authoring-plugins.md)**.
It covers the directory layout, the `plugin.yaml` schema, the runtime environment contract, and how to
install and test locally. Every plugin in this repo is a working example to copy from.

## License

[MIT](./LICENSE)
