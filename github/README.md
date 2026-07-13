# github — GitHub CLI, live PAT auth, and repo auto-clone

Installs the [GitHub CLI](https://cli.github.com/) (`gh`), wires up a git credential
helper that reads your PAT fresh from GCP Secret Manager on every git operation (so
rotations are picked up with no restart), and optionally clones repos into
`~/workspace/` on first boot. This is the one plugin enabled by default.

## What you get

```bash
$ cd ~/workspace/my-repo          # auto-cloned on first boot
$ gh pr create --fill             # authenticated via the PAT credential helper
$ git push                        # PAT fetched live from Secret Manager per operation
```

`gh` is installed at build time. On boot the plugin installs a
`git-credential-gcp-secret` helper: each git auth call runs
`gcloud secrets versions access` to read the current PAT, so rotating the secret takes
effect immediately without re-baking anything.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins github

# Or from a local clone:
ra plugin install ./github
```

`ra` prompts for config and credentials, stores secrets in GCP Secret Manager, and
applies the plugin to every subsequent `ra create`.

## Configuration

| Field       | Type          | Default | Description                                                              |
|-------------|---------------|---------|--------------------------------------------------------------------------|
| `enabled`   | bool          | `true`  | Enable the GitHub plugin.                                                |
| `repo_urls` | string_list   | *(none)*| Repos to clone into `~/workspace/<repo-name>` on first boot. Accepts `https://` or `git@github.com:owner/repo`; enter one URL per prompt, empty line to finish. |

Cloning runs in a bounded parallel pool with per-repo retries; progress is logged to
`/var/log/ra-github-clone.log`, and login shells wait for the clone to finish before
returning a prompt.

## Authentication

One provider, **PAT**:

| Secret               | Env var    | Default secret name  | Scope                                   |
|----------------------|------------|----------------------|-----------------------------------------|
| Personal Access Token| `GH_TOKEN` | `github-pat`         | classic or fine-grained, repo read+write. |

Because the credential helper reads the token live from Secret Manager, rotating the
PAT (`gcloud secrets versions add`, or re-running install with `--force`) is picked up
on the next git operation — no restart needed.
