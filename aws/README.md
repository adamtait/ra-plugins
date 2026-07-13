# aws — AWS CLI v2 with credentials injected at boot

Installs the [AWS CLI v2](https://docs.aws.amazon.com/cli/) at build time and writes a
`~/.aws/config` (region + output format) on every boot. Access keys come from GCP
Secret Manager and are injected into the environment — you never commit or paste them.

## What you get

```bash
$ aws sts get-caller-identity     # confirms the injected credentials work
$ aws s3 ls                       # start using AWS immediately
```

`aws` is installed to `/usr/local/bin/aws` at build time. On each boot the plugin
writes `~/.aws/config` (mode 600) with your default `region` and `output`; the access
key and secret arrive via `/etc/environment`, so the CLI is authenticated without an
`aws configure` step.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins aws

# Or from a local clone:
ra plugin install ./aws
```

`ra` prompts for config and credentials, stores the secrets in GCP Secret Manager, and
applies the plugin to every subsequent `ra create`. Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type   | Default     | Description                                         |
|-----------|--------|-------------|-----------------------------------------------------|
| `enabled` | bool   | `false`     | Enable the AWS CLI plugin.                          |
| `region`  | string | `us-east-1` | Default AWS region (written to `~/.aws/config`).    |
| `output`  | string | `json`      | Default output format: `json`, `yaml`, `text`, `table`. |

## Authentication

One provider, **access keys**. `ra` stores two secrets in GCP Secret Manager and
injects them into the workstation environment on boot:

| Secret                 | Env var                 | Default secret name       |
|------------------------|-------------------------|---------------------------|
| AWS Access Key ID      | `AWS_ACCESS_KEY_ID`     | `aws-access-key-id`       |
| AWS Secret Access Key  | `AWS_SECRET_ACCESS_KEY` | `aws-secret-access-key`   |

Rotate a key by re-running install with `--force`, or by adding a new Secret Manager
version and restarting the workstation.
