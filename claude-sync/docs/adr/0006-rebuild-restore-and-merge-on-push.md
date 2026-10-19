# 6. Rebuild restore, merge-on-push, and per-workstation namespaces

- Status: accepted (2026-10-19)
- Supersedes: ADR 0004 #1's "our own namespace is always skipped (push-only)", and ADR 0004 #3's
  `(project, config, email)` id (amended to add the workstation name)
- Applies to: `claude-sync` plugin (+ `stable_id` and `soft_delete_days` in `ra` core)

## Context

A rebuilt workstation came up with an almost empty `~/.claude` and the boot pull merged nothing:
"selected 0 of 40 namespace(s) … nothing to pull", exit 0. Investigation found four compounding faults:

1. **The pull skipped its own namespace.** That was safe when the namespace was the GCE instance name
   (a fresh UUID per create: anything in it was already on local disk). ADR 0004 #3 made the namespace
   stable across rebuilds, so it became the *only* place a rebuilt machine's history lives. 3,260 of
   3,262 files were never restored.
2. **Push overwrote single files.** `history.jsonl` and `claude.json` were uploaded with a plain
   `gcloud storage cp`. Within one cycle of boot, the fresh disk's near-empty copies replaced the
   previous build's. Transcripts survived only because the directory `rsync` never deletes.
3. **Two live workstations shared one namespace.** The stable id omits the workstation name, so every
   workstation built from the same config pushes to the same prefix. The bucket showed
   `history.jsonl` alternating between two writers' copies every ~5 minutes, each erasing the other.
4. **Nothing reported it.** No signal for "local is empty but my namespace isn't", and none for "someone
   else is writing my namespace".

GCS soft delete (on by default for this bucket, ~7 days) kept every overwritten generation, which made
recovery possible.

## Decision

- **Pull restores its own namespace once per disk.** When `~/.ra-claude-sync/restored-<ws-id>` is
  absent (a fresh home disk), or `claude-sync pull` forces it, `270_*.sh` restores the own namespace's
  directories, exempt from the age filter and the cap. It then writes the marker. On ordinary reboots
  only the namespace's `history.jsonl` / `claude.json` are union-merged: re-copying directories every
  boot would bring back transcripts Claude Code deliberately cleaned up, and would re-download the
  whole namespace each time.
- **Per-namespace staging, priority order.** Each namespace stages into its own directory, and the
  copy into `~/.claude` walks them own-first, then others newest-first, with `cp -an`. A shared stage
  had let an older foreign copy of a transcript replace the own namespace's newer one, which the next
  push would then upload.
- **Push merges instead of overwriting.** `history.jsonl` and `claude.json` are read-modify-written:
  read the remote object's generation, download that generation, merge the local copy in with the same
  functions the pull uses, and upload with `--if-generation-match` (`0` = must not exist). A lost race
  re-reads, up to 3 attempts, after which the cycle counts as incomplete and the manifest is not
  advanced. A failed merge aborts the upload rather than shipping the unmerged copy. Unchanged
  content isn't re-uploaded (an md5 cache of the last push, plus a compare with the remote), so idle
  workstations don't mint a soft-delete-retained generation every cycle. The local `.claude.json` is
  never modified by a push.
- **Push waits for the boot pull.** `270_*.sh` writes `/run/ra-claude-sync/pull.json`
  (`running|done|failed`, marked `running` before it detaches). The loop holds its first push until the
  state leaves `running`, with a 30-minute backstop. A missing file means "don't wait".
- **Writer identity in the manifest.** The manifest gains `writer` (GCE instance name) and
  `writer_since`. The loop reads it before overwriting it, and both scripts WARN if a different
  instance pushed within 3× interval.
- **Per-workstation stable id (core).** `ra create` derives the id from
  `(project, config, workstation name, email)`. The workstation name is itself derived from project +
  local username, so it's still stable across rebuilds.
- **Soft delete is declared, not assumed.** `buckets[].soft_delete_days: 7` in `plugin.yaml`. `ra`
  core applies it (max across plugins sharing a bucket). Chosen over object versioning, which would
  keep a *second* retained copy of every per-cycle re-upload on top of soft delete.
- **Shared library + operator command.** Merge, identity and namespace functions live once in
  `/usr/local/lib/ra-claude-sync/lib.sh` (baked by `Dockerfile.d/110_*.sh`) instead of being copied
  between 270 and 271. `/usr/local/bin/claude-sync pull|push|status` replaces running startup scripts
  by path.

## Consequences

- **One-time namespace change.** Adding the workstation name changes every workstation's id once.
  The old shared namespace becomes an ordinary *other* namespace inside the 30-day window, so the first
  boot after the change merges it. It then ages out and lifecycle reclaims it. No data is moved.
- A push cycle with changed single files makes up to 4 more gcloud calls (describe + download per
  file). Unchanged files cost none, and the shared-writer manifest read runs at most every 10 min.
- The first boot of an upgraded workstation (no marker yet) restores the own namespace once, which
  can bring back transcripts deleted locally before the upgrade.
- Two writers can still both exist (e.g. an old `ra` release). With merge-on-push they converge on the
  union instead of erasing each other, and the WARN makes it visible.
- A just-rebuilt machine may log one false shared-writer WARN if its dead predecessor pushed less than
  3× interval before the rebuild.
- `tests/run.sh` exercises the real scripts against a fake `gcloud`. Run it before changing either
  script.
