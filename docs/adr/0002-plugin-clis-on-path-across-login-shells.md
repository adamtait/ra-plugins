# 2. Exposing plugin CLIs on PATH across login shells

- Status: accepted
- Applies to: all plugins that install an executable the user runs from a shell

## Context

A plugin that installs a CLI must make it resolvable on `$PATH` under whatever
login shell the workstation ends up using. The default login shell is not fixed:
a dotfiles step can `chsh` the `user` to zsh after the image is built, and on ra
workstations it does.

`claude` and `codex` originally shipped a `profile.d/00-<plugin>-npm-path.sh` that
did `export PATH="/home/user/.npm-global/bin:$PATH"`. Files in `/etc/profile.d/`
are sourced by `/etc/profile`, which **only bash and other POSIX-`sh`-family login
shells read**. **zsh never sources `/etc/profile.d/*`** — it reads
`/etc/zsh/{zshenv,zprofile,zshrc,zlogin}`. So once the login shell became zsh, both
CLIs fell off PATH (verified on a live workstation: a real `zsh -lic` login had no
`~/.npm-global/bin` and `command -v claude` was empty). Only PATH was affected —
environment variables already reach every shell because the core runtime writes
them to `/etc/environment` (PAM, shell-agnostic), not to `profile.d/`.

Two facts about the platform shape the fix:

- **`/usr/local/bin` is on the baseline PATH of every shell and every invocation
  type** — interactive login, non-interactive `ra connect --command=...`, cron —
  before any per-user shell config runs. Most plugins already exploit this by
  installing straight into `/usr/local/bin` at build time (`aws`, `terraform`,
  `uv`, `antigravity`, `babashka`). `claude`/`codex` are the only plugins that add
  to PATH by other means, and the only ones that broke under zsh.
- **Persistence.** Cloud Workstations mounts a persistent disk at `/home` only; the
  container root (`/usr`, `/usr/local`, `/etc`) is ephemeral and reset from the
  image on every stop/start. `claude`/`codex` install at *runtime* (first boot)
  into `~/.npm-global` — under `/home`, so the binaries persist — and gate the
  install on a marker file, also under `/home`, so it runs once.

## Decision

**Put plugin CLIs on PATH by placing them in `/usr/local/bin`, never by
manipulating a shell's PATH.**

- A plugin that installs at build time installs directly into `/usr/local/bin`
  (the existing repo convention).
- A plugin that installs at runtime into a persistent-home directory (as
  `claude`/`codex` do) bakes a **build-time symlink** from `/usr/local/bin` to the
  entry point in that directory:

  ```bash
  ln -sf /home/user/.npm-global/bin/claude /usr/local/bin/claude
  ```

  The symlink must be created at **build time** (a `Dockerfile.d/` script), not in
  the runtime install script: `/usr/local/bin` is ephemeral, so a runtime-created
  link would vanish on the next stop/start, and the marker-gated installer would
  not recreate it. Baked into the image, the link is present on every boot; it
  dangles harmlessly until the first-boot install populates the target under
  `/home`, then resolves for the workstation's whole life. `ln -sf` makes it
  idempotent across rebuilds.

This replaced an earlier implementation (the reverted first version of this change)
that built a cross-shell PATH *registry* — `/etc/ra/path.d/` fragments, a loader,
per-shell entrypoints, and a dpkg `Post-Invoke` installer for `/etc/zsh/zshenv`.

### Alternatives considered and rejected

- **A — cross-shell PATH registry** (`/etc/ra/path.d/` + loader + per-shell
  entrypoints + `Post-Invoke` installer for `/etc/zsh/zshenv`). Correct and the
  most general (puts an arbitrary directory on PATH for every shell), but by far
  the most machinery: it needs a dpkg `Post-Invoke` hook to survive zsh being
  installed at boot and clobbering the `zsh-common` conffile, plus a `null_glob`
  nuance, duplicated across each PATH-adding plugin. Overkill for exposing a
  couple of named binaries.
- **B — a "zsh bridge" plugin** that makes zsh source `/etc/profile`
  (`emulate sh -c '. /etc/profile'` in `/etc/zsh/zprofile`). Simplest *mental*
  model and would fix every `profile.d`-based plugin under zsh at once, but it
  does **not** remove the hard part — `/etc/zsh/zprofile` is the same `zsh-common`
  conffile, so it still needs the `Post-Invoke` dance. It is also login-shell only
  (misses `--command`), risks breaking any `profile.d` script that uses bashisms
  when run under `emulate sh`, and needs a new bridge per future default shell.
- **D — full PATH in `/etc/environment`.** Shell-agnostic, but `/etc/environment`
  is not a script: no `$PATH` reference or prepend, so it would hard-code an
  absolute PATH that overrides rather than augments the default and does not
  compose across plugins. Poor fit.

## Consequences

- **Universal and trivial.** One symlink resolves under bash, zsh, and any other
  shell, interactive and non-interactive, with zero shell configuration — no
  `profile.d`, no `/etc/zsh`, no `Post-Invoke`, no registry. The change is
  net-negative code.
- **Scaling boundary — named entry points, not directories.** This exposes the
  specific executables a plugin knows about at build time. It deliberately does
  **not** put a whole *growing* directory on PATH (e.g. so a user's later
  `npm install -g <x>` or `go install <x>` resolves). That need belongs to the
  user's dotfiles (which already own personal PATH dirs, e.g. `~/.local/path`), or
  to a directory-on-PATH mechanism (alternative A) added only by a plugin that
  genuinely requires it. No current plugin does.
- **Runtime-install wrinkle.** The build-time symlink dangles until the first-boot
  install runs. That is invisible in practice (the CLI is not installed yet
  either), and self-heals on first boot.
- **Not covered here.** Other `profile.d` files that are also skipped under zsh but
  are not PATH additions — `github`'s clone-wait barrier and `antigravity`'s
  first-run hint — remain zsh-blind. They are unrelated to this decision and left
  as separate follow-ups.
