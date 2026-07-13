# ra-plugins

**Add a tool — and its credentials — to every `ra` cloud workstation with one command.**

Plugins for [`remote-agent`](https://github.com/adamtait/remote-agent) (`ra`), the CLI that
runs your coding agents on throwaway [Google Cloud Workstations](https://cloud.google.com/workstations)
instead of your laptop. `ra` ships with *no* built-in tooling; each plugin here is a self-contained
directory that installs a CLI, wires in its credentials from GCP Secret Manager at boot, and (for
servers) starts the process for you.

```console
$ ra plugin install https://github.com/adamtait/ra-plugins github
Enable GitHub plugin? [Y/n] y
Git repositories to clone on first boot (one per line, blank to finish):
  git@github.com:me/api.git
Auth provider [pat]: pat
GitHub Personal Access Token: ****************
# → PAT stored in GCP Secret Manager by name; nothing written to the repo or image

$ ra create
# → workstation boots with `gh` installed, the PAT wired into git's
#   credential helper, and me/api.git cloned to ~/workspace/api
```

## Why ra-plugins?

- **A directory, not a package.** Each plugin is a `plugin.yaml` plus scripts that run at image
  build, workstation boot, and shell login. `ra plugin install` copies them *verbatim* into your
  config — there's no package manager, no lockfile, and no runtime dependency back on this repo.
- **Secrets go to Secret Manager, never the image.** You paste a token once at install; `ra` stores
  the *value* in GCP Secret Manager and keeps only its *name* in config. The workstation's own
  service account fetches it at boot. Nothing sensitive is committed or baked into the Docker image.
- **Batteries included, nothing forced.** Fifteen plugins below, from `claude` to `terraform`. `ra`
  hard-codes none of them — a plugin is provisioned only because you installed it, and it self-gates
  on `RA_PLUGIN_<NAME>_ENABLED` at boot.
- **Auth your way.** Plugins that need credentials offer multiple providers: `claude` takes OAuth or
  an API key, `gcloud` takes a service-account key, a Workload Identity config, *or* the
  workstation's own attached identity, and `codex` captures a ChatGPT login or an API key.
- **Servers that start themselves.** `marimo`, `claude-science`, and `et` launch their process at
  boot and expose it over a private port tunnel (`ra tunnel <port>`) — no daemon wrangling, and
  nothing bound to the public network.

## Plugins

| Plugin | Adds |
|--------|------|
| [antigravity](./antigravity/) | The Antigravity (`agy`) CLI |
| [aws](./aws/) | AWS CLI v2, credentials injected from Secret Manager at boot |
| [babashka](./babashka/) | `bb` — a fast-starting native Clojure interpreter |
| [claude](./claude/) | Claude Code, authed by OAuth token or API key |
| [claude-science](./claude-science/) | Anthropic's AI workbench for scientists; auto-starts the server on a tunneled port |
| [claude-sync](./claude-sync/) | Syncs `~/.claude/` across workstations via a GCS bucket ([README](./claude-sync/README.md)) |
| [codex](./codex/) | OpenAI Codex CLI, authed by ChatGPT OAuth or API key |
| [et](./et/) | Eternal Terminal — `ra plugin et connect` for SSH that auto-resumes after a drop |
| [gcloud](./gcloud/) | Google Cloud CLI (SA key, Workload Identity, or attached identity) |
| [github](./github/) | GitHub CLI + PAT git credential helper; optional repo auto-clone |
| [marimo](./marimo/) | Reactive Python notebook server, auto-started at boot |
| [pulumi](./pulumi/) | Pulumi IaC CLI; optional Pulumi Cloud login via access token |
| [terraform](./terraform/) | HashiCorp Terraform CLI |
| [tmux](./tmux/) | tmux — a persistent named session at boot, auto-attached on login |
| [uv](./uv/) | `uv` — a fast Python package and project manager |

## Install

Plugins install into an existing `ra` project, so install [`ra`](https://github.com/adamtait/remote-agent)
first and run `ra setup` once. Then install a plugin by name from this repo:

```bash
ra plugin install https://github.com/adamtait/ra-plugins claude
```

From a local clone (handy while developing a plugin):

```bash
ra plugin install ./claude
```

Pin a branch, tag, or commit with `--ref`:

```bash
ra plugin install https://github.com/adamtait/ra-plugins codex --ref v1.2.0
```

Choose where it applies — `--user` (all your projects) or `--local` (this project, committed to source control):

```bash
ra plugin install https://github.com/adamtait/ra-plugins tmux --user
```

## Usage

Install a plugin, then let the next `ra create` bake it in. `ra plugin install` prompts for each
config field, the auth provider, and any secrets (hidden input); the values land in config or Secret
Manager, and every subsequent workstation picks them up.

Install several, then provision once:

```bash
ra plugin install https://github.com/adamtait/ra-plugins claude   # agent + credential helper
ra plugin install https://github.com/adamtait/ra-plugins tmux     # persistent session
ra create                                                          # boots with both
```

See what's installed and at which level, then connect:

```bash
ra plugin list
ra connect
```

Rotate a credential without editing anything — re-run the install with `--force` to capture a new
secret version (per-operation helpers like the GitHub PAT pick it up with no restart):

```bash
ra plugin install https://github.com/adamtait/ra-plugins github --force
```

Reach a server plugin's port from your machine (e.g. marimo's notebook UI):

```bash
ra tunnel 2718   # forwards marimo's edit-server port to localhost:2718
```

## Configuration

Each plugin declares its own config in `plugin.yaml` and prompts for it at install time. Two things
are worth knowing across all of them:

- **Level** — `--user` writes to `~/.config/ra/` (baseline for every project); `--local` writes to
  `.ra/` in the current project and overrides the user level. `ra plugin list` shows which is which.
- **Secrets vs. config** — config field *values* are stored in `config.yaml`; secret *values* go to
  GCP Secret Manager and only their names are kept in config. See
  [Auth & Security](https://github.com/adamtait/remote-agent/blob/main/docs/auth_and_security.md).

Plugins with richer knobs document them in their own directory — see
[`claude-sync`](./claude-sync/README.md) for a worked example.

## Creating a plugin

The authoring guide lives with the `ra` CLI:
**[Authoring `ra` plugins](https://github.com/adamtait/remote-agent/blob/main/docs/authoring-plugins.md)**.
It covers the directory layout, the `plugin.yaml` schema, the runtime environment contract, and how
to install and test locally. Every plugin in this repo is a working example to copy from.

## License

[MIT](./LICENSE) © Adam Tait
