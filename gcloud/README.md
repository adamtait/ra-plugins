# gcloud — Google Cloud CLI, authenticated three ways

Configures the [Google Cloud CLI](https://cloud.google.com/sdk/gcloud) on the
workstation and authenticates it — via a service-account key, a Workload Identity
Federation config, or the workstation's own attached identity (no key required). This
plugin **configures** `gcloud`; the binary ships with the base `ra` image.

## What you get

```bash
$ gcloud storage ls                        # uses the configured auth + default project
$ gcloud compute instances list            # scoped to your default region/zone
```

On every boot the plugin writes your default `project`/`region`/`zone` into
`~/.config/gcloud`, then authenticates using the provider you chose. For the
`service_account` and `workload_identity` providers it also exports
`GOOGLE_APPLICATION_CREDENTIALS`, so client libraries (ADC) pick up the same identity.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins gcloud

# Or from a local clone:
ra plugin install ./gcloud
```

`ra` prompts for config and credentials, stores secrets in GCP Secret Manager, and
applies the plugin to every subsequent `ra create`. Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type   | Default | Description                              |
|-----------|--------|---------|------------------------------------------|
| `enabled` | bool   | `false` | Enable the Google Cloud CLI plugin.      |
| `project` | string | `""`    | Default GCP project ID.                  |
| `region`  | string | `""`    | Default compute region (e.g. `us-central1`). |
| `zone`    | string | `""`    | Default compute zone (e.g. `us-central1-a`). |

## Authentication

Choose one provider at install time:

| Provider           | Secret / env var             | Default secret name   | Notes                                              |
|--------------------|------------------------------|-----------------------|----------------------------------------------------|
| `service_account`  | `GCLOUD_SA_KEY_B64`          | `gcloud-sa-key`       | Base64 of a service-account JSON key.              |
| `workload_identity`| `GCLOUD_WIF_CONFIG_B64`      | `gcloud-wif-config`   | Base64 of a WIF credential-config JSON.            |
| `host_identity`    | *(none)*                     | —                     | Uses the workstation's attached service account via the GCE metadata server. |

`host_identity` needs no secret and is the simplest option when the workstation's own
service account already has the roles you need. Rotate a keyed credential by re-running
install with `--force`.
