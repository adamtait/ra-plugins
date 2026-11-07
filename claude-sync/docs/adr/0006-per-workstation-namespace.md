# 6. Per-workstation namespace, single-writer guard, and periodic pull

- Status: accepted (2026-11-07)
- Partially supersedes: [ADR 0004](./0004-load-reduction.md) #3 (stable namespace). The stable id is
  now the namespace *stem*, not the whole namespace.
- Applies to: `claude-sync` plugin

## Context

Two workstations, `p` and `pp`, were created from the same Workstations config. Both pushed to
`claude-sync/workstations/<stable-id>/`. ADR 0004 #3 derived that id from
`(project, config_name, user_email)` and assumed one workstation per config. That assumption doesn't
hold: ra core sets `RA_PLUGIN_CLAUDE_SYNC_NAMESPACE` as a container env var on the **config**, so every
workstation under the config gets the same value. ra core can't fix this, because config-level env
can't differ per workstation. The result:

- **Overwrites.** `history.jsonl` and `claude.json` are stored as one file per namespace, so each
  machine's push replaced the other's every cycle. pp's copies were lost. If the same session was open
  on both machines, each `gcloud storage rsync` push also replaced the other's copy of that transcript.
- **Invisible sessions.** The boot pull skips "own namespace (push-only)". The shared namespace was
  both machines' own namespace, so neither ever pulled the other's sessions.
- **Boot-only arrival.** Even with distinct namespaces, sessions from another machine only arrived at
  the next boot.

## Decision

1. **Namespace = `<stable-id>--<hostname>`.** On Cloud Workstations the hostname is the workstation
   name. It is unique within a config and survives restarts. It's lowercased and restricted to
   `[a-z0-9_-]` (core's `idSafeRe` rule). Core never puts `--` in a stable id, so the double hyphen
   is an unambiguous join. A workstation rebuilt under the same name reuses its namespace, which keeps
   ADR 0004's no-churn goal. If the hostname is empty or `localhost`, a random suffix is generated once
   and kept in `/home/user/.ra-claude-sync/ws-suffix`. With no stable id at all, the legacy
   `resolve_ws_id()` (instance name) is used as before.
2. **Single-writer guard.** The manifest now carries `writer_host` and `writer_instance` (the GCE
   instance name). At startup the push loop reads its own namespace's manifest. While a *different*
   instance has pushed within the last 3 push intervals, the loop logs `ERROR namespace collision`
   and waits, re-checking every 3 intervals, without pushing. It doesn't exit, because under the
   `setsid` fallback nothing would restart it. Once the foreign writer goes quiet, for example the
   previous instance of a rebuilt workstation, the loop takes the namespace over.
3. **Pull as a reusable script, run at boot and periodically.** `270_*.sh` writes out
   `/usr/local/lib/ra-claude-sync/common.sh` (shared helpers, replacing the copy-in-two-places
   functions) and `/usr/local/bin/ra-claude-sync-pull.sh`, then runs the pull detached with `--boot`.
   The push loop runs the same script in the background every `pull_interval_seconds` (default 600;
   0 disables it), so a slow pull never delays pushes. A `flock` stops two pulls from overlapping.
   The loop's first push waits (up to 15 minutes) for the boot pull to write
   `/run/ra-claude-sync.boot-pull.done`. Otherwise it could overwrite our own namespace's
   `claude.json` and `history.jsonl` before the boot pull restored them.
4. **Incremental shared mirror.** There is one mirror tree per subtree under
   `/var/cache/ra-claude-sync/mirror/`. Each selected namespace is rsynced over it and merged before
   the next one is rsynced, so every namespace's version of a file is considered. Files identical
   across namespaces, which is most of them because workstations re-push what they pull, are
   downloaded and stored once. A per-namespace mirror would have cost N × the full history in disk
   and bandwidth. `/var` resets on restart, so the first pull after boot is a full download, as
   before, and the home disk doesn't grow.
5. **Per-file merge rules** (`merge_tree`), replacing `cp -an`:
   - missing locally → copy in;
   - remote strictly larger, local is a byte prefix of it, and local is idle (not modified in the
     last 120s) → **fast-forward** with an atomic replace. This covers a session continued on
     another machine;
   - remote larger but diverged → keep local, logged as `keep-local`;
   - equal or smaller → keep local silently, because local is current or ahead.

   Nothing is ever deleted, and an active or diverged local file is never overwritten.
6. **Safe write-back for shared single files.** `history.jsonl` (every pull) and `.claude.json`
   (boot only) are written back only if the local file's size, inode and nanosecond mtime didn't
   change during the merge. `history.jsonl` retries up to 3 times. Temp files inherit the
   destination's owner and mode before the rename, so a file Claude Code appends to never becomes
   root-owned. Fast-forward temp files live in `~/.ra-claude-sync/tmp`, which is on the same
   filesystem but outside the pushed tree, so a concurrent push never uploads one. Newly copied
   files are chowned right after the copy, and an EXIT trap chowns `~/.claude` on every exit path.
7. **Our own namespace is merged at boot only.** It restores a rebuilt workstation's history.
   Periodically it would only re-download what we just pushed.

## Consequences

- **Migration is automatic.** The old shared `<stable-id>` namespace matches no workstation, so
  every workstation pulls it as a normal namespace while it's within `pull_max_age_days`. Nothing
  writes to it any more, and the bucket lifecycle rules eventually remove it. The pp `history.jsonl`
  and `claude.json` copies lost before this change can't be recovered from the bucket.
- **Duplicated storage, unchanged from before.** A workstation re-pushes sessions it pulled into its
  own namespace, so active sessions exist once per workstation that has seen them. Other workstations
  then mirror those copies too. That costs bandwidth, but `merge_tree` ignores them because they are
  never larger than the local copy.
- **A large, active transcript is re-downloaded whole** whenever it grows, about once per pull
  interval. GCS has no partial-object sync. A 500 MB transcript continued on another machine costs
  roughly that much per interval while it's active.
- **Diverged transcripts stay diverged.** If one session is continued on two machines, each keeps its
  own version and the pull logs `keep-local` every interval. Reconciling them would need a
  JSONL-aware merge, which is out of scope.
- **A small race remains.** There are microseconds between the final unchanged-check and the
  `rename(2)`. Closing that would need Claude Code to cooperate on locking.
- **Local deletions don't stick.** A file deleted locally is copied back from any namespace that
  still has it, now within one pull interval rather than at the next boot. That includes this
  workstation's own earlier pushes. Deletions never propagated in this design (ADR 0002). Fixing it
  would need a record of files seen locally, or tombstones.
- **Files that differ across namespaces are re-downloaded each pull.** The shared mirror flips
  between each namespace's version of such a file, typically an active session.
- **The guard depends on metadata.** Without a resolvable instance name the guard is skipped. That's
  the same fail-open stance as ADR 0002's `resolve_ws_id`.
