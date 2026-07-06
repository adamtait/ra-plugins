# gcloud plugin — implementation notes

Running log of decisions, deviations from the plan/spec, and tradeoffs made while
building the `gcloud` plugin (modeled on `aws`, with the credential-handling shape of
`codex`).

## Decisions not fully specified up front

- **Auth model = service-account key.** The clarifying questions timed out (user away),
  so I went with the most faithful analog to `aws` (which injects static access keys):
  a service-account JSON key. Host-identity-only (no secret, just `gcloud config`) was
  the alternative and remains an easy follow-up as a second auth provider if wanted.

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
  (client libraries), but the `gcloud` CLI itself uses its own credential store, so I
  also run `gcloud auth activate-service-account` as the workstation user (the boot
  script runs as root but the gcloud config/credential DB belongs to `user`).
  Activation failure logs a `WARNING` and does **not** abort boot (per the
  auth-hardening convention from commit `f78f98d`).

- **`_clear_stale_state`.** Mirrors `codex`: on every boot, `ra_env_unset`
  `GOOGLE_APPLICATION_CREDENTIALS` and `GCLOUD_SA_KEY_B64` and remove the key file
  before re-activating, so rotating the key or disabling the provider never leaves a
  stale credential where a login shell still sources it.

## Install hook tradeoffs

- **Idempotent, skips if `gcloud` exists.** gcloud appears preinstalled in the base
  image (the `github` plugin and the core call `gcloud` directly), so in practice the
  guard makes this a no-op. Kept it anyway to (a) mirror the `aws` structure and (b)
  stay safe on any base image lacking gcloud. If gcloud is guaranteed present, the whole
  `Dockerfile.d/` hook could be dropped.

- **Rapid channel, unpinned.** Installs the latest from the `rapid` channel tarball,
  matching `aws`'s "always latest, no version pinned by design" stance. Downloads to a
  temp file before `tar` (never pipe `curl --retry` into `tar`) and uses the standard
  `CURL_RETRY` flags.

- **arch mapping.** Google's tarballs use `x86_64` and `arm` (not `aarch64`); mapped
  `uname -m` accordingly. Symlinks `gcloud`, `gsutil`, `bq` into `/usr/local/bin` so
  they're on PATH without a `profile.d/` entry (same as `aws` landing in
  `/usr/local/bin`).

## Things to know / open questions

- **Key file persists on disk** at `~/.config/gcloud/ra-service-account.json`
  (`chmod 600`, owned by `user`). Required because `GOOGLE_APPLICATION_CREDENTIALS`
  points at it. This matches the security posture of `aws` (static keys) and `codex`
  (decoded `auth.json` on disk).

- **No `profile.d/`** needed — install symlinks handle PATH, and env vars go through
  the ra-env helper into `/etc/environment`.

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
