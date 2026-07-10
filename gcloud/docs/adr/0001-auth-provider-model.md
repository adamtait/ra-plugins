# 1. gcloud auth-provider model

- Status: accepted
- Applies to: `gcloud` plugin

## Context

The `gcloud` plugin configures the Google Cloud CLI and Application Default Credentials (ADC) on a
workstation at boot. It is modeled on the `aws` plugin (inject a static credential + write config)
but must cover more auth shapes, and it runs on **Google Cloud Workstations**, where the gcloud CLI
is already present in the base image and the workstation has its own attached service account.

## Decision

### Three auth providers

- **`service_account`** — the faithful analog to `aws`: a base64-encoded service-account JSON key
  (`GCLOUD_SA_KEY_B64`) is decoded at boot into a `0600` file and activated with
  `gcloud auth activate-service-account --key-file`.
- **`workload_identity`** — a Workload Identity Federation credential *configuration*
  (`type: external_account`), transported the same way (base64 blob → `0600` file) and activated with
  `gcloud auth login --cred-file`. `auth login` takes no `--project`, so the project comes from the
  gcloud config file the plugin writes. The WIF config is itself a valid ADC file, so it doubles as
  `GOOGLE_APPLICATION_CREDENTIALS` for client libraries.
- **`host_identity`** — **no secret**: gcloud and ADC authenticate via the GCE metadata server using
  the workstation's own attached service account. The plugin schema is purpose-built for the
  secret-less case (a provider need not declare secrets; a provider may instead declare `iam_roles`
  to grant the workstation service account roles). `host_identity` declares no `iam_roles` by default;
  a YAML comment shows how to add them.

### Supporting decisions

- **Base64 secret, not a `value_command`.** A GCP SA key is multi-line JSON and cannot live in an env
  var directly, so it is stored base64-encoded and decoded at boot — identical to how `codex` handles
  its `auth.json`. No `value_command` auto-capture is provided: unlike `codex login`, there is no
  canonical local command that yields an SA key (users download it from the console or
  `gcloud iam service-accounts keys create`), so the user supplies the blob at install time (the
  description hints `base64 -w0 key.json`). A `value_command` reading a fixed key path is a possible
  later enhancement.
- **A shared decode helper** (`_write_credential_file`) base64-decodes the blob into a `0600` file and
  JSON-validates it; the `service_account` and `workload_identity` branches then differ only in the
  `gcloud` command they run.
- **gcloud config is written as a file, not via `gcloud config set`.** The plugin writes gcloud's INI
  `configurations/config_default` directly (idempotent overwrite), mirroring how `aws` writes
  `~/.aws/config`. This keeps the non-secret path deterministic and avoids invoking `gcloud` for it.
  Only sections/keys with a non-empty value are emitted. The active config is pinned by writing
  `active_config = default`, so the generated file is the one gcloud actually reads even if the base
  image left another named config active.
- **Two-layer activation.** Exporting `GOOGLE_APPLICATION_CREDENTIALS` covers ADC (client libraries),
  but the gcloud CLI keeps its own credential store, so for the credential-file providers the plugin
  also runs a CLI-side activation **as the workstation user** (the boot script runs as root, but the
  gcloud credential DB belongs to the user). Activation failure logs a `WARNING` and does not abort
  boot (see the cross-cutting boot-environment ADR).
- **Stale-state clearing every boot** (`_clear_stale_state`): before re-authenticating, unset the
  credential env vars and remove the decoded files, so rotating a key/config or switching providers
  never leaves a stale credential where a login shell still sources it. Because `/home` persists across
  boots, `host_identity` additionally runs `gcloud auth revoke --all` (`|| true`) to force the CLI to
  fall back to the metadata identity instead of staying pinned to a previously-activated key.
- **No install hook.** The plugin ships **no** `Dockerfile.d/` gcloud install: the Cloud Workstations
  code-oss base image guarantees `gcloud` (other plugins call `gcloud` at runtime with no install).
  An install hook would be dead code and diverge from the repo's convention for this dependency. The
  configure script degrades gracefully if gcloud were ever absent (the activation call only warns, and
  `GOOGLE_APPLICATION_CREDENTIALS` is still exported for ADC).

## Consequences

- **Credential files persist on disk** (`~/.config/gcloud/ra-service-account.json` or
  `ra-wif-cred-config.json`, each `0600`, user-owned) because `GOOGLE_APPLICATION_CREDENTIALS` points
  at them — the same security posture as `aws` (static keys) and `codex` (decoded `auth.json`). The
  `~/.config/gcloud` directory is created as the user at `0700`.
- No `profile.d/` is needed: gcloud is already on `PATH`, and env vars flow through the shared
  `ra-env` helper into `/etc/environment`.
- The full end-to-end path (`ra plugin install` → `ra create`) requires a real GCP project; it was
  verified statically (syntax, shellcheck, YAML parse, and a local dry-run of the configure logic).
