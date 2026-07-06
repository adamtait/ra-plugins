# gcloud plugin — implementation notes

Running log of decisions, deviations from the plan/spec, and tradeoffs made while
building the `gcloud` plugin (modeled on `aws`, with the credential-handling shape of
`codex`).

## Decisions not fully specified up front

- **Three auth providers: `service_account`, `workload_identity`, `host_identity`.**
  - `service_account` — the faithful analog to `aws` (inject a static credential):
    base64-encoded SA JSON key → `gcloud auth activate-service-account --key-file`.
  - `workload_identity` — a Workload Identity Federation credential *configuration*
    (`type: external_account`, produced by `gcloud iam workload-identity-pools
    create-cred-config`) → `gcloud auth login --cred-file`. Same base64-blob transport
    as the SA key. `auth login` takes no `--project` flag, so the project comes from the
    config file we write. The WIF cred config is itself a valid ADC file, so it also
    doubles as `GOOGLE_APPLICATION_CREDENTIALS` for client libraries.
  - `host_identity` — no secret: gcloud and ADC authenticate via the GCE metadata
    server using the workstation's own attached service account.
  The remote-agent schema is purpose-built for the secret-less case:
  `AuthProvider.Secrets` is optional (fileplugin.go only validates that the *selected*
  provider name exists), and `AuthProvider.iam_roles` exists precisely to "grant the
  workstation service account [roles] ... instead of a stored secret" (schema.go). The
  `host_identity` provider declares no `iam_roles` by default — a YAML comment shows how
  to add them.

- **Shared decode helper.** `service_account` and `workload_identity` both base64-decode
  a JSON blob into a 0600 file and JSON-validate it; that logic is factored into
  `_write_credential_file` so the two branches differ only in the `gcloud` command they
  run (`activate-service-account --key-file` vs `login --cred-file`).

- **Base64 secret, not a `value_command`.** A GCP SA key is multi-line JSON and can't
  live in an env var directly, so it's stored base64-encoded (`GCLOUD_SA_KEY_B64`) and
  decoded at boot — identical to how `codex` handles `auth.json`. I did **not** add a
  `value_command` to auto-capture the key: unlike `codex login`, there's no canonical
  local command/path that yields an SA key (users download it from the console or
  `gcloud iam service-accounts keys create`). So the user supplies the base64 blob at
  `ra plugin install` time. The `plugin.yaml` description hints `base64 -w0 key.json`.
  A `value_command` reading a fixed key path is a possible later enhancement.

- **Config written as a file, not via `gcloud config set`.** I write gcloud's INI
  `configurations/config_default` directly (idempotent `>` overwrite), mirroring how
  `aws` writes `~/.aws/config`. This avoids invoking `gcloud` for the non-secret path
  and keeps the config deterministic. Only sections/keys with a non-empty value are
  emitted, so an all-empty config yields an empty file rather than half-populated
  stanzas.

- **`config_default` filename.** gcloud's active config is stored at
  `~/.config/gcloud/configurations/config_default`. That's the default named config;
  writing it directly is the documented layout and is what `gcloud config set` would
  produce for the default configuration.

## Deviations / additions vs. the aws template

- **Uses the ra-env helper.** Unlike `aws` (which writes no env vars, only a config
  file), this plugin must export `GOOGLE_APPLICATION_CREDENTIALS` so ADC / client
  libraries find the key. That's an env var login shells need, so the script sources
  the shared `/usr/local/lib/ra/ra-env.sh` helper with the same inline fallback block
  `codex`/`claude` use. Copied verbatim to keep the both-file (`/etc/environment` +
  `/run/ra/env`) contract identical.

- **Two-layer auth activation.** Setting `GOOGLE_APPLICATION_CREDENTIALS` covers ADC
  (client libraries), but the `gcloud` CLI itself uses its own credential store, so for
  the credential-file providers we also run a CLI-side activation as the workstation
  user (the boot script runs as root but the gcloud config/credential DB belongs to
  `user`): `gcloud auth activate-service-account` for `service_account`, and
  `gcloud auth login --cred-file` for `workload_identity`. Activation failure logs a
  `WARNING` and does **not** abort boot (per the auth-hardening convention from commit
  `f78f98d`).

- **`_clear_stale_state`.** Mirrors `codex`: on every boot, before re-authenticating,
  `ra_env_unset` `GOOGLE_APPLICATION_CREDENTIALS`, `GCLOUD_SA_KEY_B64`, and
  `GCLOUD_WIF_CONFIG_B64`, and remove both credential files (`KEY_FILE`, `CRED_FILE`).
  So rotating a key/config or switching providers never leaves a stale credential where
  a login shell still sources it.

## No install hook (removed after confirming gcloud is a base-image guarantee)

The plugin originally shipped an idempotent `Dockerfile.d/100_gcloud-install.sh` that
installed the Cloud SDK unless `gcloud` was already on PATH — mirroring the `aws`
plugin's structure. It was **removed** once confirmed redundant:

- These are **Google Cloud Workstations**, and gcloud is preinstalled in the code-oss
  base image. `claude-sync/Dockerfile.d/110_claude-sync-tools.sh` states it outright
  ("curl and gcloud are guaranteed by the Cloud Workstations code-oss base image") and
  deliberately does **not** install gcloud — it only soft-warns. `github` and
  `claude-sync` both call `gcloud` at runtime with no install. Google's docs confirm the
  predefined base images bundle the gcloud CLI.
- So the install hook was dead code in practice and diverged from the repo's own
  convention for this dependency. Dropping it collapses the plugin to `plugin.yaml` +
  the configure script.
- Safe to drop: the configure script degrades gracefully if gcloud were ever missing —
  the `sudo -u user gcloud auth …` call only logs a `WARNING` (doesn't abort boot), and
  `GOOGLE_APPLICATION_CREDENTIALS` is still exported for ADC/client libraries.

(The install hook it referenced used Google's tarball naming `x86_64`/`arm` — not
`aarch64` — for the record, in case a future base image ever drops gcloud and it needs
re-adding.)

## Things to know / open questions

- **Credential file persists on disk** — `~/.config/gcloud/ra-service-account.json`
  (`service_account`) or `~/.config/gcloud/ra-wif-cred-config.json`
  (`workload_identity`), each `chmod 0600`, owned by `user`. Required because
  `GOOGLE_APPLICATION_CREDENTIALS` points at it. This matches the security posture of
  `aws` (static keys) and `codex` (decoded `auth.json` on disk).

- **No `profile.d/`** needed — the base image already has gcloud on PATH, and env vars
  go through the ra-env helper into `/etc/environment`.

- **`host_identity` revokes stale gcloud creds.** Cloud Workstations persist `/home`
  (so `~/.config/gcloud` survives across boots). Switching `service_account` →
  `host_identity` therefore needs to clear the account a prior boot activated, or the
  gcloud CLI would stay pinned to that now-removed key instead of falling back to the
  metadata identity. The `host_identity` branch runs `gcloud auth revoke --all`
  (`|| true`, since it errors when there's nothing to revoke) to force that fallback.
  ADC is already handled by `_clear_stale_state` unsetting `GOOGLE_APPLICATION_CREDENTIALS`.

- The **end-to-end path (`ra plugin install` → `ra create`)** can't be exercised here
  (no `ra` CLI / GCP project in this environment); verified statically instead
  (syntax, shellcheck, YAML parse, and a local dry-run of the configure script logic).

## Changes from code review (`/review`)

- **Drop to the user with `sudo -u user`, not `runuser`.** The repo idiom is
  `sudo -u "${USER_NAME}"` (claude/codex/github/tmux/marimo all use it); `runuser` was
  used nowhere. Switched the `gcloud auth activate-service-account` call to
  `sudo -u user env CLOUDSDK_CONFIG=… gcloud …`, which also pins the config location
  and removes the unstated `runuser` dependency.
- **Config dir created as the user + `chmod 0700`.** `mkdir -p` as root left the
  intermediate `~/.config` root-owned and the SA key briefly at 0644 in a 0755 dir.
  Now `sudo -u user mkdir -p` (github idiom) keeps `~/.config` user-owned, and 0700 on
  `~/.config/gcloud` shields the key file regardless of its momentary mode — same
  hardening `codex` applies to `CODEX_HOME`.
- **Pin the active config.** Write `~/.config/gcloud/active_config` = `default` so the
  `config_default` file we generate is actually the one gcloud reads (guards against a
  base image leaving another named config active).
