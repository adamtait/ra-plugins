# Architecture Decision Records

This directory holds [ADRs](https://adr.github.io/) — short records of significant, durable design
decisions and the reasoning behind them.

**Layout:** decisions that apply across plugins live here at the top level. Decisions specific to one
plugin are co-located in that plugin's own `docs/adr/` directory.

Each ADR follows a lightweight *Context / Decision / Consequences* form.

## Cross-cutting ADRs

- [0001 — Plugin boot-time environment and auth-hardening conventions](./0001-plugin-boot-environment-and-auth-conventions.md)
- [0002 — Exposing plugin CLIs on PATH across login shells](./0002-plugin-clis-on-path-across-login-shells.md)

## Plugin-specific ADRs

- **et** — [`et/docs/adr/`](../../et/docs/adr/)
  - [0001 — python3 local port helpers (macOS bash SIGABRT fix)](../../et/docs/adr/0001-python3-local-port-helpers.md)
- **gcloud** — [`gcloud/docs/adr/`](../../gcloud/docs/adr/)
  - [0001 — gcloud auth-provider model](../../gcloud/docs/adr/0001-auth-provider-model.md)
- **claude-sync** — [`claude-sync/docs/adr/`](../../claude-sync/docs/adr/)
  - [0001 — GCS-backed cross-workstation state sync](../../claude-sync/docs/adr/0001-gcs-state-sync-architecture.md)
  - [0002 — Merge-based sync for append-only / shared files](../../claude-sync/docs/adr/0002-merge-based-sync.md)
  - [0003 — Daemon launch: setsid fallback when systemd is not PID 1](../../claude-sync/docs/adr/0003-daemon-launch-setsid-fallback.md)
  - [0004 — Load reduction: filtered pull, stable namespace, bucket lifecycle](../../claude-sync/docs/adr/0004-load-reduction.md)
  - [0005 — Bucket naming, shared-bucket prefixing, and cross-project sync](../../claude-sync/docs/adr/0005-bucket-naming-and-namespacing.md)
  - [0006 — Rebuild restore, merge-on-push, and shared-namespace safety](../../claude-sync/docs/adr/0006-rebuild-restore-and-merge-on-push.md)
