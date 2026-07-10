# 1. Plugin boot-time environment and auth-hardening conventions

- Status: accepted
- Applies to: all plugins that run `workstation-startup.d/` scripts or export environment

## Context

Every plugin that needs credentials or configuration at runtime runs one or more
`workstation-startup.d/` scripts on each boot of the Google Cloud Workstation. Several
independent plugins (`claude`, `codex`, `gcloud`, `github`, `marimo`, `tmux`, `claude-sync`)
converged on the same handful of conventions for how those scripts source secrets, export
environment, drop privileges, and handle auth failures. Rather than re-derive the reasoning in
each plugin, this ADR records the shared conventions once.

The core `ra` runtime fetches each install's secrets and configuration at boot and writes them to
`/run/ra/env` (mode 0600, owned by the workstation user), also propagating them into
`/etc/environment` for login shells. Plugin startup scripts run **after** that step.

## Decision

1. **Startup ordering ≥ 250.** Plugin `workstation-startup.d/` scripts use numeric prefixes of
   `250` or higher so they always run after the core boot step that fetches secrets and writes
   `/run/ra/env`. A script sources that file (`set -a && . /run/ra/env && set +a`) to pick up its
   `RA_PLUGIN_*` config and any secret env vars, then exits early if its
   `RA_PLUGIN_<NAME>_ENABLED` flag is not `true`.

2. **Both-file env contract via the shared `ra-env` helper.** A plugin that must export an
   environment variable for login shells (e.g. `GOOGLE_APPLICATION_CREDENTIALS`,
   `CLAUDE_CODE_OAUTH_TOKEN`) does so through the shared helper at
   `/usr/local/lib/ra/ra-env.sh` (`ra_env_set` / `ra_env_unset`), which updates **both**
   `/etc/environment` and `/run/ra/env`, deduped. If the helper is somehow absent (a newer plugin
   booting against an older core), scripts carry an **inline fallback** implementing the identical
   both-file contract, so behavior is the same whether or not the helper is present. `claude`,
   `codex`, and `gcloud` all use this pattern verbatim.

3. **Drop privileges with `sudo -u <user>`.** Startup scripts run as root with a near-empty
   environment. When an action must run as the workstation user (writing into their home, using a
   per-user credential store), scripts use `sudo -u "${USER_NAME}"` — the repo-wide idiom — rather
   than `runuser` or other mechanisms. Per-user config directories are created **as the user** and
   locked to `0700` so a credential file is never briefly world-readable in a `0755` parent.

4. **Auth activation warns, never aborts boot.** A failure to activate a credential (bad key,
   transient CLI error) logs a `WARNING` and lets boot continue; it does **not** `exit 1` the
   startup script. A half-authenticated workstation the user can fix is better than a workstation
   that fails to come up at all.

5. **Clear stale credential state on every boot before re-authenticating.** Because Cloud
   Workstations persist `/home` across stop/start, a switch of auth provider or a rotated secret
   could otherwise leave a stale credential that a login shell still sources. Scripts `ra_env_unset`
   the relevant vars and remove decoded credential files at the top of each boot, then re-apply the
   current configuration.

## Consequences

- New plugins have a consistent, copy-pasteable shape for boot-time setup; reviewers can check a
  script against these five points.
- The inline fallback duplicates a small amount of shell across plugins, accepted so that a plugin
  never silently diverges from the both-file contract when the shared helper is missing.
- "Warn, don't abort" means a misconfigured credential surfaces as a runtime auth failure (with a
  log line) rather than a failed boot — the intended tradeoff.
