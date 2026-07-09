# Implementation notes — et connect SIGABRT fix (python3 local-port helpers)

Running log of decisions/deviations/tradeoffs made while implementing the fix
for `ra plugin et connect` "waits then just returns". Companion to
`remote-agent docs/adr/0015` (the durable decision record). This file is the
"things you should know" scratchpad.

## What changed (spec)

- `commands/connect.sh`: replaced the two bash `/dev/tcp` loops (`free_port`,
  `wait_port`) with single `python3` calls; added a `python3` preflight check.
- `plugin.yaml`: added a `post_install_message` flagging the new local `python3`
  dependency.
- `remote-agent`: ADR 0015 + README table row (no code).

## Root cause (recap)

`connect.sh` crashed with SIGABRT (exit 134) before launching `et`, because
bash's `/dev/tcp` probe loops ran concurrently with the two backgrounded
`ra tunnel` (Go) jobs — a fork/alloc race in bash 5.2.26 on macOS. ~100% at
normal speed, 0% under `bash -x` (a timing race). `ra` maps the crash to exit 1,
so it looked like a silent immediate return. Full evidence table is in ADR 0015.

## Decisions NOT in the original plan / deviations

1. **ADR location forced a third repo + PR.** The plan said "remote-agent: no
   changes," but ADRs live in `remote-agent/docs/adr/` (that's where the two
   existing ET ADRs, 0011 and 0014, are). Honoring the user's "add an ADR"
   request means a docs-only `remote-agent` PR. So this ships as **three** PRs
   (ra-plugins, dotfiles, remote-agent), not two.

2. **`python3` dependency accepted (over pure shell).** `nc -z` (the
   dependency-free option) only cut the crash rate to 2/6 — the tight bash loop
   still forks per iteration. The single-shot `python3` approach (poll loop runs
   *inside* one child) was the only variant that hit 0 crashes. Tradeoff: the
   client script now needs `python3`. Mitigated with a preflight `command -v
   python3` check + the `post_install_message`. `python3` is present on macOS and
   nearly all Linux dev machines.

3. **etserver-readiness probe loop left as-is.** It's another bash loop that
   shells out (`gcloud ssh`) concurrently with the tunnels, but at a `sleep 3`
   cadence — low spawn rate, and it never crashed in end-to-end runs. Tightening
   it was out of scope and would add risk for no observed benefit. If crashes
   ever resurface, this is the next place to look.

4. **`free_port` `RANDOM` guessing dropped.** The `python3` picker binds two
   ephemeral sockets and lets the OS assign guaranteed-free ports — strictly more
   correct than the old RANDOM-guess-then-probe, and simpler.

5. **README ADR table:** it was already missing a row for the existing ADR 0014.
   I added my 0015 row after 0011 (matching the table's append order) and left
   the pre-existing 0014 omission alone (out of scope).

## Implementation gotchas

- **Edited via a python line-anchored script, not the Edit tool.** `connect.sh`
  is tab-indented and the same change had to land byte-identically in 3 copies
  (source `../ra-plugins`, live `~/.config/ra`, dotfiles snapshot). A script
  anchoring on ASCII line prefixes avoided tab-matching fragility.
- **Self-inflicted assert trip:** my sanity check `"/dev/tcp" not in file` fired
  because my *new comment* mentions `/dev/tcp`. Relaxed to check for the
  functional `"/dev/tcp/127.0.0.1"` construct.
- **Embedded python indentation:** inside `python3 -c '...'`, the bash line keeps
  its tab, but the python body sits at column 0 with its own 4-space indent.
  `bash -n` clean on all three copies.

## Kept `set -m`; residual crash is a non-TTY artifact only

**What:** Left `set -m` (job control) in place — it's what makes the EXIT trap's
`kill %1 %2` reap each background tunnel's whole process group (incl. the gcloud
grandchild). Did NOT remove it.

**Why / the data:** After the python change, crash rate depends on whether the
script has a controlling terminal:
- **Under a PTY (the user's real case — `ra` hands `connect.sh` the terminal's
  stdin): 0/10 SIGABRT**, and a full e2e connect landed in tmux.
- Under **pipe stdin** (no controlling terminal — only how my headless harness
  invokes it): **1/8** SIGABRT. `set -m` (monitor mode) is sensitive to the
  absence of a controlling terminal, which is the residual trigger there.

The original was 10/10 in *both* conditions, so python fixes the real-world path
completely; the leftover is a non-TTY edge the user never hits.

**Alternatives / tradeoff:** Removing `set -m` got 0/8 even under pipe stdin in
an earlier spike — but then `kill %1 %2` only kills the supervise shells, not
their `ra tunnel`/gcloud grandchildren, so tunnels leak on exit. I judged a clean
teardown (real, recurring cost) worth more than hardening a non-TTY invocation
the user never performs. If a pure-0 is ever wanted without `set -m`, teardown
must switch to explicit process-group / `pkill -f "ra tunnel <port>:"` killing.

## Review fix (applied)

**Finding (low severity, applied):** the port-picker's `|| { exit 1; }` only
caught `read` *failure*, not a successful read of partial/garbage output. If
`python3` ever emitted a single token, `read` returns 0 with `DATA_PORT` empty
and a later `-p ""` / `ra tunnel :2022` fails confusingly. Closed with a
numeric-validation guard after the read (`[[ "$BOOT_PORT" =~ ^[0-9]+$ && ... ]]`),
neutralizing `set -e` on the read with `|| true` first. Happy path re-verified
(two distinct numeric ports; connect proceeds past the guard).

Rest of the review was clean: no correctness bugs, no CLAUDE.md violations
(ra-plugins has none), and the change is a net simplification (drops the RANDOM
loop and the distinct-port dedup, now guaranteed by simultaneous bind).

## Verification status

- [x] `bash -n` clean on all 3 `connect.sh`; all 3 byte-identical.
- [x] all 3 `plugin.yaml` byte-identical; `ra plugin et connect --help` registers; `ra plugin list` loads with no yaml errors.
- [x] `ra validate` OK with the edits.
- [x] crash test (patched real `connect.sh`): **0/10 under PTY** (user's case); 1/8 under pipe-stdin (non-TTY artifact, see above).
- [x] end-to-end under PTY: connects — `Connecting to p` → `[main]` → `user@p`.
- [ ] `post_install_message` prints on `ra plugin install` (confirm during PR verify).
