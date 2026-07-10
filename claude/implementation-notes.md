# claude plugin — implementation notes

Running log of decisions and tradeoffs behind the parts of this plugin that aren't
obvious from the scripts. Currently this covers the **cross-shell PATH mechanism**
(`Dockerfile.d/110_claude-shell-path.sh`), which is shared, plugin-agnostic wiring
that the `codex` plugin mirrors byte-for-byte.

## The problem

`claude` is installed with `npm install -g` into `/home/user/.npm-global/bin` (not
on the default PATH). The original fix put `export PATH="…/.npm-global/bin:$PATH"`
in `profile.d/00-claude-npm-path.sh`, i.e. `/etc/profile.d/`. That is sourced only
by **bash / POSIX-`sh` login shells** (via `/etc/profile`). **zsh never sources
`/etc/profile.d/*`** — it reads `/etc/zsh/{zshenv,zprofile,zshrc,zlogin}`. So once
the workstation's default login shell became zsh (a dotfiles step runs `chsh`),
`claude` and `codex` fell off PATH. Env vars are unaffected because they go through
`/etc/environment` (PAM, shell-agnostic); only PATH-via-`profile.d` broke.

## The design: a `/etc/ra/path.d` registry, one loader, per-shell entrypoints

Separate **what** goes on PATH (plugin data) from **how** each shell loads it
(shared, written once):

- **`/etc/ra/path.d/<key>.sh`** — one guarded POSIX fragment per directory. Keyed by
  the *directory* (`10-npm-global.sh`), not the plugin, so `claude` and `codex` —
  both installing into `.npm-global` — write byte-identical content and converge on
  a single PATH entry. The `case` guard makes re-sourcing idempotent.
- **`/etc/ra/load-path.sh`** — the only copy of the load logic; sources
  `path.d/*.sh`. Pure POSIX so every shell reads it.
- **Per-shell entrypoints**, each a one-line source of the loader:
  `/etc/profile.d/00-ra-path.sh` (bash/sh/dash/ksh) and a managed block in
  `/etc/zsh/zshenv` (zsh). A future shell (fish, …) is one more one-liner.

Adding a new PATH-adding plugin is then a one-file drop-in: ship the same generic
wiring and change only the fragment's directory.

## Decisions worth recording

- **zsh target is `/etc/zsh/zshenv`, not `zlogin`/`zprofile`.** zshenv is sourced by
  *every* zsh invocation, so it fixes non-interactive `ra connect --command="claude …"`,
  cron and scripts too — strictly more than the old bash behavior, which only ever
  covered login shells. zsh's own docs designate zshenv as the file for the command
  search path.

- **The zsh entrypoint is installed by a dpkg `Post-Invoke` hook, not written at
  build time.** On ra workstations zsh is installed *at boot* by a detached
  (`setsid --fork`) dotfiles step that finishes after the sequential startup scripts,
  and `/etc/zsh/zshenv` is a `zsh-common` dpkg **conffile** that `apt install zsh`
  clobbers. A `Post-Invoke` hook (`/etc/apt/apt.conf.d/99-ra-shell-path` →
  `/usr/local/sbin/ra-shell-path-install`) re-runs the idempotent installer after
  *any* apt transaction, immune to ordering and conffile clobbering. A one-time run at
  build covers images that already ship zsh. This is the same mechanism the `tmux`
  plugin uses (`tmux/Dockerfile.d/110_tmux-zsh-autoattach.sh`) and for the same reason.
  Bound: it only fires if zsh arrives via apt; a from-source/snap zsh would be missed,
  with the POSIX `/etc/profile.d` entrypoint as the backstop.

- **The zsh entrypoint sources the loader inside an anonymous function with
  `local_options null_glob`.** The loader globs `/etc/ra/path.d/*.sh`; zsh has
  `NOMATCH` on by default, so an empty registry (loader present, no fragments) would
  print `no matches found` to stderr on *every* zsh. `null_glob` silences that;
  `local_options` (only valid inside a function, hence the anonymous `() { … }`)
  auto-reverts the option on exit, while `export PATH` still escapes to the parent
  shell. The loader itself stays pure POSIX — the one zsh-ism lives only in the
  zsh-only entrypoint. (The empty state doesn't occur in normal install/remove/build,
  but a file in `zshenv` must degrade silently.)

- **The wiring is duplicated (convergently), not shared via a library.** `claude`
  and `codex` each ship a full copy of `110_<plugin>-shell-path.sh`; the files differ
  only in header comments. This matches the repo's "self-contained plugin over shared
  library" convention (a user may enable `codex` without `claude`) and is safe because
  every write is idempotent and content-identical — the two converge on the same files
  rather than colliding.

## Verification

Validated end-to-end on a live zsh-default workstation (no full rebuild) by running
the build script's body post-hoc: `claude` and `codex` resolve under `zsh -lic`
(interactive login), `zsh -c` (non-interactive, proves `zshenv`), and `bash -lc`;
the managed block and `path.d` fragment stay singular after re-running both plugins'
installers; and the block survives an `apt --reinstall zsh-common` (the `Post-Invoke`
hook re-runs). Canonical validation is `ra plugin install ./claude ./codex` + `ra create`.
