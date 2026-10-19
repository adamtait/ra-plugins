# claude-sync

**Your Claude Code history, todos, plans, and memory follow you to every workstation — not your laptop.**

A [`remote-agent`](https://github.com/adamtait/remote-agent) plugin that syncs `~/.claude/` across
cloud workstations sharing a `(GCP project, git user email)` pair. Each workstation pushes its state
to a private GCS bucket on a short loop; on boot, every other workstation's state is merged back in.

```console
$ ra plugin install https://github.com/adamtait/ra-plugins claude-sync
Enable claude-sync? [y/N] y
Seconds between push cycles of ~/.claude/ to GCS [60]:
Override the auto-derived GCS bucket name (empty = use ra-<project>-<hash>):
# → next `ra create` provisions gs://ra-<project>-<hash> and grants the
#   workstation service account objectAdmin on it

# Workstation A, Monday: you run a Claude Code session.
# Workstation B, Tuesday — the boot pull merges A's state into ~/.claude/:
$ claude          # up-arrow replays A's prompts; A's transcripts, todos,
                  # and plans are already under ~/.claude/projects
```

## Why claude-sync?

- **State outlives any single workstation.** Session transcripts, todos, plans, per-session env, the
  global command log, and per-project `CLAUDE.md` memory land in `~/.claude/` on every workstation —
  hand a session off between machines, or review usage across all of them from one place.
- **An allowlist, not a blob.** Exactly the six paths below are pushed each cycle; PIDs, caches, the
  npm plugin dir, and shell snapshots are excluded by design, so nothing machine-local leaks.
- **Rebuilds restore themselves.** A rebuilt workstation reuses its namespace. On a fresh home disk
  the boot pull restores that namespace first, outside the age and count limits. Ordinary reboots skip
  it, so transcripts you deleted stay deleted.
- **No write contention.** Each workstation writes to its own namespace prefix and the boot pull
  *union-merges* the others. Pushes of `history.jsonl` / `.claude.json` merge with the remote copy
  (generation-checked) instead of overwriting it, so even two machines on one namespace converge.
- **Bounded growth, logged — not silently capped.** The boot pull merges only namespaces pushed
  within `pull_max_age_days` and caps at the `pull_max_namespaces` most recent; GCS lifecycle rules
  demote data to Coldline at 90 days and delete at 365. Every exclusion is logged as `skip <ns>: <reason>`.

## What gets synced

Pushed every cycle (allowlist). The first push waits for the boot pull to finish:

- `projects/` — session transcripts (UUID-named JSONLs) and per-project memory directories.
- `todos/`, `plans/`, `session-env/` — UUID-keyed todo, plan, and per-session env state.
- `history.jsonl` — global command log. **Union-merged** on boot: it is append-only and each
  workstation holds only a partial view, so copies are merged, never overwritten.
- `.claude.json` — global config. The **local** file wins for all machine-local fields (auth,
  onboarding, counters); only per-project `history` arrays are unioned in from other workstations.

Excluded (deliberately local): `shell-snapshots/`, `sessions/`, `plugins/`, `cache/`, `backups/`, `statsig/`.

## Install

```bash
ra plugin install https://github.com/adamtait/ra-plugins claude-sync
```

Enable it (default `false` → say yes) and accept the defaults unless you have a specific bucket name
to reuse. The next `ra create` will, idempotently:

1. Create the bucket `ra-<project>-<sha1(git-user-email)[:8]>` (or your `bucket_name_override`).
2. Bind `roles/storage.objectAdmin` on it to the workstation service account.
3. Inject `RA_PLUGIN_CLAUDE_SYNC_BUCKET` and a stable `RA_PLUGIN_CLAUDE_SYNC_NAMESPACE` so a rebuilt
   workstation reuses one namespace instead of spawning a fresh ~85 MB one each create.
4. Apply the bucket's GCS Object Lifecycle rules (see [Storage lifecycle](#storage-lifecycle)).

claude-sync syncs files created by the [`claude`](../claude/) plugin (or a manual Claude Code
install). With neither present, pushes are no-ops — install both together.

## Architecture

The bucket name omits "claude" so other plugins can share it under their own prefixes. See the
[ADRs](./docs/adr/) for the full design.

```
Workstation A ──┐                              ┌── Workstation C
                ├── gs://ra-<proj>-<hash>/  ───┤
Workstation B ──┘     claude-sync/             └── Workstation D
                        workstations/<ws-id>/...
                        _manifest/<ws-id>.json
```

- Each workstation pushes to `claude-sync/workstations/<ws-id>/`. `ra create` derives `<ws-id>` from
  (project, workstation config, email), so it's stable across rebuilds. It's shared by every
  workstation on that config, including a rebuild's old and new machines while both run.
- Boot pull merges its own namespace (restore) plus the recent other namespaces into `~/.claude/`:
  directory trees via `cp -an` (local files win), `history.jsonl` via union-merge, `.claude.json` via
  local-base + per-project history union. Progress goes to `/run/ra-claude-sync/pull.json`.
- Pushes of the two single files are read-modify-write with `--if-generation-match`. Directories
  `rsync` without deletes.
- `_manifest/<ws-id>.json` carries `last_push_at_epoch` (advanced only on a fully successful push
  cycle; drives the pull's recency ranking) and `writer`, the instance that pushed it.

## Configuration

| Field                  | Type   | Default                     | Notes                                                                 |
|------------------------|--------|-----------------------------|-----------------------------------------------------------------------|
| `enabled`              | bool   | `false`                     | Master switch.                                                        |
| `interval_seconds`     | int    | `60`                        | Push cadence. Below 10 amortizes the gcloud cold-start cost poorly.   |
| `bucket_name_override` | string | (derive `ra-<proj>-<hash>`) | Must be valid GCS naming (lowercase, 3–63 chars, no underscores).     |
| `sync_all_projects`    | bool   | `false`                     | User-level install only. Points every project's workstations at one shared bucket. |
| `pull_max_age_days`    | int    | `30`                        | Boot pull merges only *other* namespaces pushed within N days. `0` = cap-only. Own namespace is always merged. |
| `pull_max_namespaces`  | int    | `15`                        | Boot pull caps the merge to the N most-recently-pushed *other* namespaces. |

## Operations

```console
$ claude-sync status   # bucket, namespace, loop, last pull/push, shared-writer warning
$ claude-sync pull     # merge remote state into ~/.claude now, incl. full own-namespace restore (sudo)
$ claude-sync push     # one push cycle now (sudo)
```

- **Logs**: `/var/log/ra-claude-sync.log` on each workstation. Lines to look for: `include <ns>: own
  namespace (restore)`, `restored N file(s) into projects/`, `WARN: fresh local state …`,
  `WARN: namespace … shared with live writer …`.
- **Process check**: `claude-sync status`, or the PID in `/run/ra-claude-sync.pid`. Cloud Workstations
  run `entrypoint.sh` as PID 1 (not systemd), so the `setsid` fallback is what runs in production;
  `systemctl status` reporting "Failed to connect to bus" there is expected, not the bug.
- **Restart the loop**: re-run `/etc/workstation-startup.d/271_claude-sync-daemon.sh` as root
  (idempotent: SIGTERM the PID in `/run/ra-claude-sync.pid`, then relaunch).
- **Inspect a namespace**: `gcloud storage ls gs://<bucket>/claude-sync/workstations/<ws-id>/projects/`.
- **Tests**: `bash claude-sync/tests/run.sh` runs the real scripts against a fake `gcloud` (no root, no
  network). Run it before changing either script.

### Restore from soft delete

The bucket keeps overwritten and deleted objects for `soft_delete_days` (7). To recover a lost
`history.jsonl` (same for `claude.json`):

```bash
obj=gs://<bucket>/claude-sync/workstations/<ws-id>/history.jsonl
gcloud storage objects list --soft-deleted "$obj" --format='value(generation,size,update_time)'
gcloud storage restore "$obj#<generation>"   # becomes the live object until the next push
gcloud storage cp "$obj" /tmp/restored.jsonl  # then: claude-sync pull, or merge by hand
```

Restoring makes the old copy live again. The next push merges your local copy into it, so restored
lines survive the next cycle as well.

### Storage lifecycle

The bucket declares two GCS lifecycle rules in `plugin.yaml`, both scoped to the `claude-sync/`
prefix so they never touch other plugins' objects: **Coldline after 90 days** and **Delete after
365 days** (well beyond the 30-day boot-pull TTL, so anything deleted is provably unused). `ra create`
applies them idempotently; tune the horizons by editing `buckets[].lifecycle` and re-running.

To reclaim a specific dead workstation's namespace immediately:

```bash
gcloud storage rm -r "gs://<bucket>/claude-sync/workstations/<old-ws-id>/"
gcloud storage rm "gs://<bucket>/claude-sync/_manifest/<old-ws-id>.json"
```

## ⚠️ Security: transcripts contain whatever Claude saw

Session JSONLs under `projects/<cwd>/` capture full conversational history — shell output, tool
results, pasted content — and flow verbatim into the GCS bucket.

- The bucket is IAM-locked to the workstation SA + project owners, with Google-managed encryption.
- **Do not enable this plugin on workstations handling data you would not also store in a private
  GCS bucket.** For high-sensitivity environments, run `ra` without it (or wait for v2's CMEK /
  client-side encryption).

## Caveats

- Up to `interval_seconds` of state can be lost if a workstation is killed between push cycles.
- `gcloud storage rsync` re-uploads whole files on any byte change — a 50 MB session JSONL re-uploads
  fully each cycle. v2 plans a delta-append approach.
- Parallel `CLAUDE.md` memory edits on two workstations resolve by last-merge-order on pull; no
  conflict UI yet.
- Two live workstations on one config (typically a rebuild's new machine while the old one still
  runs) share a namespace. Pushes merge, so nothing is lost, but `claude-sync status` and the log warn
  about a second writer. Delete the old workstation once the new one is set up.
- `.claude.json` merge can create a project entry holding only a `history` array for projects you've
  never opened here (so up-arrow history works when you first `cd` in); Claude fills the rest with defaults.

## License

[MIT](../LICENSE) © Adam Tait
