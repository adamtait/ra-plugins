# pulumi — Pulumi infrastructure-as-code CLI

Installs the [Pulumi](https://www.pulumi.com/) CLI and, if you provide a Pulumi Cloud
access token, wires it into the environment so `pulumi up` works with no login step.

## What you get

```bash
$ pulumi new aws-typescript      # scaffold a project
$ pulumi up                       # provision — authenticated if a token was configured
```

Pulumi installs at **first boot** into `~/.pulumi/bin` (on the persistent `/home`
disk), and a build-time symlink puts it on `PATH` as `pulumi`. The release tarball is
**SHA256-verified** before install. Installing at boot (not build) is what lets you pin
an exact version through config.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins pulumi

# Or from a local clone:
ra plugin install ./pulumi
```

`ra` prompts for config and the optional token, stores secrets in GCP Secret Manager,
and applies the plugin to every subsequent `ra create`. Set `enabled` to `true` when
prompted.

## Configuration

| Field     | Type   | Default  | Description                                                     |
|-----------|--------|----------|-----------------------------------------------------------------|
| `enabled` | bool   | `false`  | Install the Pulumi CLI.                                          |
| `release` | string | `latest` | Version to install, e.g. `3.252.0`, or `latest` for the newest. |

## Authentication

The `access_token` provider is **optional** — skip it for self-managed backends.

| Secret                | Env var                | Default secret name    |
|-----------------------|------------------------|------------------------|
| Pulumi Cloud token    | `PULUMI_ACCESS_TOKEN`  | `pulumi-access-token`  |

With a token configured, it is exported via `/etc/environment` and `pulumi up` runs
against Pulumi Cloud with no `pulumi login`. Without one, log in yourself:

```bash
pulumi login                 # Pulumi Cloud
pulumi login --local         # local filesystem backend
pulumi login s3://my-bucket  # self-managed backend
```
