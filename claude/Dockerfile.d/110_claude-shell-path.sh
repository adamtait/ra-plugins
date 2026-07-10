#!/bin/bash
# Claude plugin — make /home/user/.npm-global/bin (where `npm install -g` places
# the claude binary) discoverable under *any* login shell, not just bash.
#
# Why this exists:
#   The old approach shipped /etc/profile.d/00-claude-npm-path.sh, which is
#   sourced only by *bash* (and other POSIX sh-family) login shells via
#   /etc/profile. When the workstation's login shell is zsh — e.g. a dotfiles
#   step runs `chsh` — that file never fires (zsh login shells source
#   /etc/zsh/{zshenv,zprofile,zshrc,zlogin}, never /etc/profile.d/*), so `claude`
#   drops off PATH. This installs a shell-agnostic PATH mechanism instead.
#
# The mechanism (shared, plugin-agnostic — see claude/implementation-notes.md):
#   /etc/ra/path.d/<key>.sh   — one guarded POSIX fragment per PATH directory
#   /etc/ra/load-path.sh      — the single loader that sources path.d/*.sh
#   /etc/profile.d/00-ra-path.sh          — POSIX sh-family login entrypoint
#   /etc/zsh/zshenv (managed block)       — zsh entrypoint (all invocations)
#   /usr/local/sbin/ra-shell-path-install — installs the zsh entrypoint
#   /etc/apt/apt.conf.d/99-ra-shell-path  — dpkg Post-Invoke re-runs the installer
#
# Everything here is generic and idempotent, written with `>` (overwrite) and
# guarded appends, so any other PATH-adding plugin (e.g. codex) that ships an
# identical copy of this wiring *converges* on the same files rather than
# colliding. This plugin's only unique contribution is the npm-global fragment.
#
# Why a dpkg Post-Invoke hook wires the zsh entrypoint rather than a build-time
# write: on ra workstations zsh is typically installed at *boot* by an external
# dotfiles step that detaches itself (setsid --fork), finishing after the
# sequential startup scripts have run; and /etc/zsh/zshenv is a `zsh-common` dpkg
# conffile that a later `apt-get install zsh` would clobber. A Post-Invoke hook
# runs the installer right after *any* apt transaction — including the one that
# installs zsh — with no dependence on startup ordering or timing. The once-at-
# build run (step 6) covers zsh already present in the image.
#
#   Assumption: zsh reaches the workstation via apt/apt-get (the ra dotfiles path
#   does). A bare `dpkg -i`, snap, or from-source zsh would not fire Post-Invoke;
#   the POSIX /etc/profile.d entrypoint remains the backstop there.
set -euo pipefail

# 1. Registry directory for PATH fragments.
mkdir -p /etc/ra/path.d

# 2. This plugin's fragment: prepend the npm-global bin. Keyed by directory
#    (npm-global), not plugin, so codex — which installs into the same prefix —
#    writes byte-identical content and the two converge to a single entry. The
#    `case` guard makes it idempotent when re-sourced (nested/interactive shells).
#    Quoted heredoc => `$PATH` is stored verbatim, not expanded at build time.
cat > /etc/ra/path.d/10-npm-global.sh <<'RA_FRAGMENT_EOF'
# npm global bin — where `npm install -g` places CLIs (claude, codex, ...).
# Shared by any plugin that installs into this prefix; keyed by directory so
# multiple plugins converge on one PATH entry.
case ":$PATH:" in
  *:/home/user/.npm-global/bin:*) ;;
  *) export PATH="/home/user/.npm-global/bin:$PATH" ;;
esac
RA_FRAGMENT_EOF
chmod 0644 /etc/ra/path.d/10-npm-global.sh

# 3. The single loader. The only place that knows how to load fragments; each
#    shell family's entrypoint just sources this. Pure POSIX sh so bash/sh/dash/
#    ksh and zsh all read it (no arrays, no `[[`). Under POSIX sh a non-matching
#    glob leaves the pattern literal, which `[ -r ]` skips; zsh would instead
#    error on an unmatched glob (NOMATCH), so its entrypoint sources this under
#    `null_glob` (step 5) rather than complicating the loader with shell checks.
cat > /etc/ra/load-path.sh <<'RA_LOADER_EOF'
# ra plugins — source every registered PATH fragment (see /etc/ra/path.d/).
# Single source of the load logic; per-shell entrypoints just source this file.
for _f in /etc/ra/path.d/*.sh; do
  [ -r "$_f" ] && . "$_f"
done
unset _f
RA_LOADER_EOF
chmod 0644 /etc/ra/load-path.sh

# 4. POSIX sh-family login entrypoint (bash/sh/dash/ksh). Not a conffile, and the
#    dotfiles step never touches /etc/profile.d, so this needs no Post-Invoke.
cat > /etc/profile.d/00-ra-path.sh <<'RA_PROFILE_EOF'
# ra plugins — load PATH fragments for POSIX sh-family login shells.
# zsh gets the same via /etc/zsh/zshenv (see ra-shell-path-install).
[ -r /etc/ra/load-path.sh ] && . /etc/ra/load-path.sh
RA_PROFILE_EOF
chmod 0644 /etc/profile.d/00-ra-path.sh

# 5. Idempotent installer for the zsh entrypoint: append a guarded `source` line
#    to /etc/zsh/zshenv. No-op unless zsh is installed and the block is not
#    already present. Quoted heredoc => stored verbatim.
cat > /usr/local/sbin/ra-shell-path-install <<'RA_INSTALLER_EOF'
#!/bin/bash
# Idempotently wire the ra PATH loader into /etc/zsh/zshenv, so zsh shells (which
# never source /etc/profile.d/*) pick up the same PATH fragments as bash. Invoked
# from a dpkg Post-Invoke hook and once at image build. No-op unless zsh is
# installed and the block is not already present.
#
# We append to /etc/zsh/zshenv, a `zsh-common` dpkg conffile (zsh has no
# zshenv.d drop-in). zshenv is sourced by *every* zsh invocation, so this also
# covers non-interactive `ra connect --command=...`. The only side effect is that
# an in-place `apt upgrade` of zsh-common may show a conffile prompt
# (noninteractive keeps our version) — acceptable given the fresh-root-each-boot
# model. The guard greps the load-bearing `source` line (not a comment), and the
# block is one printf, so a half-written block is repaired on the next run.
#
# The source runs inside a zsh anonymous function with `local_options null_glob`
# so an empty /etc/ra/path.d (loader present, no fragments) is a silent no-op
# instead of a NOMATCH error on every shell; local_options auto-reverts the
# option on function exit, and `export PATH` still escapes to the parent shell.
set -eu
ZSHENV=/etc/zsh/zshenv
command -v zsh >/dev/null 2>&1 || exit 0
[ -d /etc/zsh ] || exit 0
grep -qsF 'source /etc/ra/load-path.sh' "${ZSHENV}" 2>/dev/null && exit 0
printf '\n%s\n%s\n%s\n' \
  '# >>> ra path (managed) >>>' \
  '[ -r /etc/ra/load-path.sh ] && () { setopt local_options null_glob; source /etc/ra/load-path.sh }' \
  '# <<< ra path (managed) <<<' >> "${ZSHENV}"
RA_INSTALLER_EOF
chmod 0755 /usr/local/sbin/ra-shell-path-install

# 6. dpkg Post-Invoke: run the installer after every apt transaction. `|| true`
#    so it can never fail an apt operation. This is what catches the boot-time
#    zsh install regardless of startup ordering.
cat > /etc/apt/apt.conf.d/99-ra-shell-path <<'RA_APT_EOF'
DPkg::Post-Invoke { "/usr/local/sbin/ra-shell-path-install || true"; };
RA_APT_EOF
chmod 0644 /etc/apt/apt.conf.d/99-ra-shell-path

# 7. Cover images that already have zsh at build time.
/usr/local/sbin/ra-shell-path-install || true
