#!/bin/bash
# github plugin: block login-shell startup until 260_github-clone.sh has
# finished. Without this, sshd accepts a connection as soon as the core
# /run/ra/ready sentinel is up (created by 200_remote-agent-setup.sh) — but
# the github clone runs in a separate startup script and may still be in
# progress, leaving ~/workspace with only an empty .git/.
#
# 260_github-clone.sh always touches the marker on exit (including when the
# plugin is disabled), so this wait completes fast in the no-clone case too.
#
# Timeout:
#   The core sentinel wait (00-ra-wait.sh) uses RA_WAIT_TIMEOUT_SECONDS for an
#   entrypoint that runs in <5s. Cloning is a different workload: a single
#   small repo finishes in seconds, but a first boot cloning several (or large)
#   repos can take minutes. Reusing a flat 60s here mis-fires as a "failure" on
#   a perfectly healthy multi-repo clone, so we size the wait to the number of
#   configured repos instead (RA_PLUGIN_GITHUB_REPO_URLS was already sourced
#   into this shell by 00-ra-wait.sh). Override with RA_GITHUB_WAIT_TIMEOUT_SECONDS.
#
# Sources after /etc/profile.d/00-ra-wait.sh thanks to the 01- prefix.

GITHUB_MARKER="${HOME}/.ra-github-first-boot-done"

# Count non-empty pipe-separated repo URLs (POSIX-safe; login shell may be dash).
_ra_github_repo_count() {
    _urls="${RA_PLUGIN_GITHUB_REPO_URLS:-}"
    [ -z "${_urls}" ] && { echo 0; return; }
    _n=0
    _oldifs="${IFS}"
    IFS='|'
    for _u in ${_urls}; do
        [ -n "${_u}" ] && _n=$((_n + 1))
    done
    IFS="${_oldifs}"
    echo "${_n}"
}

if [ -n "${RA_GITHUB_WAIT_TIMEOUT_SECONDS:-}" ]; then
    _ra_github_timeout="${RA_GITHUB_WAIT_TIMEOUT_SECONDS}"
else
    _ra_github_n="$(_ra_github_repo_count)"
    # 30s base + 45s per configured repo. Clones run in parallel, so this is
    # generous headroom rather than a tight sum, and never dips below 60s.
    _ra_github_timeout=$((30 + 45 * _ra_github_n))
    [ "${_ra_github_timeout}" -lt 60 ] && _ra_github_timeout=60
fi

if [ ! -e "${GITHUB_MARKER}" ]; then
    waited=0
    while [ ! -e "${GITHUB_MARKER}" ] && [ "${waited}" -lt "${_ra_github_timeout}" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ ! -e "${GITHUB_MARKER}" ]; then
        echo "github plugin: repo clone still running after ${_ra_github_timeout}s." \
             "It continues in the background; ~/workspace will finish populating shortly" \
             "(progress in /var/log/ra-github-clone.log)." >&2
    fi
fi

unset _ra_github_timeout _ra_github_n _urls _n _oldifs _u 2>/dev/null || true
