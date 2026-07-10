# 1. Use python3 for local port allocation/probing in `et connect`

- Status: accepted
- Applies to: `et` plugin, `commands/connect.sh`

## Context

`ra plugin et connect` connects to a workstation through the local Eternal Terminal (`et`) client.
`et` needs two local endpoints — an SSH bootstrap tunnel and the etserver data channel — so
`connect.sh` brings up two supervised local tunnels and points `et` at them. To do that it must
pick two free local ports and wait for each tunnel to start accepting connections.

The original implementation did this in pure bash: a `RANDOM`-based guess loop plus `/dev/tcp`
probes to test whether a port was free / live. Running those tight `/dev/tcp` probe loops
**concurrently with the two backgrounded tunnel jobs** triggered a fatal `SIGABRT` (exit 134) in
bash before `et` ever launched — a fork/allocation race in bash on macOS, reproducing at roughly
100% at normal speed but 0% under `bash -x` (a timing race). Because the crash surfaced to the
user as an immediate silent return, it looked like `connect` "waits then just returns."

## Decision

Replace the bash `/dev/tcp` loops with single `python3` invocations, and add a `python3` preflight
check to `connect.sh`.

- **Port allocation:** one `python3` process binds two ephemeral sockets at once and prints the two
  OS-assigned ports. This is strictly more correct than guess-then-probe — the OS guarantees the
  ports are free and distinct — and removes the `RANDOM` loop and the distinct-port dedup entirely.
- **Readiness probe:** one `python3` process runs the whole poll loop internally, so bash does not
  spawn a probe per iteration while the background tunnel jobs are alive.

Keeping every local-port operation inside a single `python3` child is what avoids the fork/probe
storm that crashes bash.

## Consequences

- **New local dependency: `python3`.** Mitigated with a `command -v python3` preflight (with an
  install hint) and a `post_install_message` on the plugin. `python3` is present on macOS and nearly
  all Linux dev machines. The dependency-free alternative (`nc -z`) only cut the crash rate to ~2/6
  because the tight bash loop still forks per iteration; the single-shot `python3` approach was the
  only variant that reached zero crashes.
- **`set -m` (job control) is retained**, because the `EXIT` trap's `kill %1 %2` relies on it to reap
  each background tunnel's whole process group (including the tunnel's grandchild), giving a clean
  teardown with no leaked tunnels. Measured after the python change: **0/10 SIGABRT under a real PTY**
  (the user's actual path, where `ra` hands `connect.sh` the terminal) with a full end-to-end connect
  succeeding; a residual ~1/8 only under pipe-stdin (no controlling terminal), which is a non-TTY
  artifact of monitor mode that the real invocation never hits. Removing `set -m` reached 0/8 even
  under pipe-stdin but left tunnels leaking on exit — a real, recurring cost judged worse than
  hardening an invocation the user never performs. If a pure-zero without `set -m` is ever wanted,
  teardown must switch to explicit process-group killing (e.g. `pkill -f "ra tunnel <port>:"`).
- **The etserver-readiness probe loop is left as pure bash**: it shells out (`gcloud ssh`) at a
  `sleep 3` cadence — a low enough spawn rate that it never crashed in end-to-end runs. Tightening it
  was unnecessary risk. It remains the first place to look if crashes ever resurface.
- **Port-picker output is numeric-validated** after the read: a successful read of partial/garbage
  output (not just a read failure) is caught by a `[[ "$BOOT_PORT" =~ ^[0-9]+$ && ... ]]` guard, so a
  malformed allocation fails loudly instead of producing a confusing empty-port `et`/tunnel error.

## References

- The companion decision record on the CLI side lives in the
  [`remote-agent`](https://github.com/adamtait/remote-agent) repo
  (`docs/adr/0015`), which carries the full crash-reproduction evidence for the bash `/dev/tcp`
  SIGABRT.
