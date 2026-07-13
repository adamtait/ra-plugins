# terraform — HashiCorp Terraform, baked in

Installs the [Terraform](https://www.terraform.io/) CLI at image build time so a new
`ra` workstation can plan and apply infrastructure immediately.

## What you get

```bash
$ terraform init && terraform plan
```

The official release archive is downloaded and **SHA256-verified** against HashiCorp's
published checksums, then installed to `/usr/local/bin/terraform` (on `PATH` at boot).

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins terraform

# Or from a local clone:
ra plugin install ./terraform
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.

## Configuration

| Field     | Type | Default | Description                             |
|-----------|------|---------|-----------------------------------------|
| `enabled` | bool | `false` | Install Terraform on the workstation.   |

Installs the latest release resolved from HashiCorp's checkpoint API; there is no
version-pin option. For cloud credentials, pair this with the [`aws`](../aws/),
[`gcloud`](../gcloud/), or another provider plugin.
