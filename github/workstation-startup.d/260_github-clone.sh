#!/bin/bash
# GitHub plugin — first-boot git identity setup + repo clone.
#
# Reads from the standard ra contract:
#   GIT_USER_NAME, GIT_USER_EMAIL  (set by core)
#   RA_PLUGIN_GITHUB_ENABLED
#   RA_PLUGIN_GITHUB_REPO_URLS     (pipe-separated list of https:// or git@github.com:... URLs)
#
# Guarded by FIRST_BOOT_MARKER — only runs once per workstation.
#
# Clones run in parallel and each is retried a few times; per-repo output is
# captured to CLONE_LOG so a failed clone is diagnosable instead of silently
# swallowed. The login-shell barrier (profile.d/01-github-clone-wait.sh) waits
# on FIRST_BOOT_MARKER, which is always touched on exit.
set -euo pipefail

USER_NAME="user"
USER_HOME="/home/${USER_NAME}"
WORKSPACE_DIR="${USER_HOME}/workspace"
FIRST_BOOT_MARKER="${USER_HOME}/.ra-github-first-boot-done"
CLONE_LOG="/var/log/ra-github-clone.log"

# Per-repo retry policy for transient clone failures (network blips, large
# repos, credential helper not yet warm).
CLONE_MAX_ATTEMPTS="${RA_GITHUB_CLONE_MAX_ATTEMPTS:-3}"
CLONE_RETRY_DELAY="${RA_GITHUB_CLONE_RETRY_DELAY:-3}"

# Concurrency cap for the bounded worker pool below. Clones are both network-
# and CPU-bound (index-pack delta resolution + checkout), so unbounded fan-out
# thrashes and can trip GitHub secondary rate limits once the repo list is
# large. Default to the core count, but ceiling it at 8: GitHub's secondary
# limits are per-account/IP (not per-core), so more than a handful of parallel
# clones mostly buys rate-limit risk rather than throughput. Override (up or
# down) with RA_GITHUB_CLONE_JOBS.
CLONE_JOBS="${RA_GITHUB_CLONE_JOBS:-}"
if [ -z "${CLONE_JOBS}" ]; then
    _cores="$(nproc 2>/dev/null || echo 4)"
    if [ "${_cores}" -gt 8 ]; then CLONE_JOBS=8; else CLONE_JOBS="${_cores}"; fi
    unset _cores
fi
case "${CLONE_JOBS}" in ''|*[!0-9]*) CLONE_JOBS=4 ;; esac
[ "${CLONE_JOBS}" -lt 1 ] && CLONE_JOBS=1

# Optional shallow clone (opt-in). Biggest single per-repo lever for many/large
# repos: skipping full history cuts both transfer and the CPU-bound delta
# resolution. Off by default because it changes checkout semantics (truncated
# history, single branch). Set RA_GITHUB_CLONE_DEPTH=1 (or N) to enable.
CLONE_DEPTH="${RA_GITHUB_CLONE_DEPTH:-}"

[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a

[ -e "${FIRST_BOOT_MARKER}" ] && exit 0

# Always touch the marker on exit so the per-plugin profile.d barrier
# (01-github-clone-wait.sh) doesn't hang for the full timeout when the plugin is
# disabled or when this script aborts before the clone runs.
mark_done() {
    touch "${FIRST_BOOT_MARKER}"
    chown "${USER_NAME}:${USER_NAME}" "${FIRST_BOOT_MARKER}"
}
trap mark_done EXIT

[ "${RA_PLUGIN_GITHUB_ENABLED:-false}" = "true" ] || exit 0

# Log both to CLONE_LOG and to the startup script's stdout/stderr.
log() { echo "[github-clone] $*" | tee -a "${CLONE_LOG}" >&2; }

: >>"${CLONE_LOG}" || true
log "first-boot clone starting ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

# Git identity (used by any subsequent git ops in the workstation).
if [[ -n "${GIT_USER_NAME:-}" ]]; then
    sudo -u "${USER_NAME}" git config --global user.name "${GIT_USER_NAME}"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    sudo -u "${USER_NAME}" git config --global user.email "${GIT_USER_EMAIL}"
fi

sudo -u "${USER_NAME}" mkdir -p "${WORKSPACE_DIR}"

# clone_one REPO_URL — normalize, skip-if-present, clone with retries.
# Returns non-zero and records the URL under FAIL_DIR only after exhausting all
# attempts. Runs backgrounded, so per-repo output is written to CLONE_LOG
# (interleaving on stderr is avoided) and the parent tallies FAIL_DIR rather
# than relying on per-PID wait status (which the pool's `wait -n` may reap).
clone_one() {
    local REPO_URL="$1"
    local marker_id="$2"  # unique per repo; names this worker's failure marker

    # Normalize SSH GitHub URLs to HTTPS — workstation has only HTTPS creds (PAT
    # via the credential helper) and no SSH keys / known_hosts.
    case "${REPO_URL}" in
        git@github.com:*)
            local rest="${REPO_URL#git@github.com:}"
            rest="${rest%.git}"
            REPO_URL="https://github.com/${rest}.git"
            echo "[github-clone] normalized SSH URL to ${REPO_URL}" >>"${CLONE_LOG}"
            ;;
    esac

    # Extract repo name: last path component, strip .git suffix.
    local repo_name="${REPO_URL##*/}"
    repo_name="${repo_name%.git}"
    # Reject anything that isn't a single safe path component. Empty, ".", ".."
    # or a name containing "/" would make clone_target escape WORKSPACE_DIR
    # (e.g. ".." -> /home/user), turning the rm -rf below into a destructive
    # operation on the wrong directory.
    case "${repo_name}" in
        ""|.|..|*/*)
            echo "[github-clone] WARNING: refusing unsafe repo name '${repo_name}' from ${REPO_URL}; skipping." >>"${CLONE_LOG}"
            return 0
            ;;
    esac

    local clone_target="${WORKSPACE_DIR}/${repo_name}"
    if [[ -d "${clone_target}/.git" ]]; then
        echo "[github-clone] ${clone_target} already cloned; skipping." >>"${CLONE_LOG}"
        return 0
    fi
    # Never clobber pre-existing content: if something already occupies the
    # target that isn't our git checkout, leave it untouched. Otherwise a failed
    # clone's rm -rf (below) would delete user data the plugin didn't create.
    if [[ -e "${clone_target}" ]]; then
        echo "[github-clone] WARNING: ${clone_target} exists but is not a git repo; leaving it untouched." >>"${CLONE_LOG}"
        return 0
    fi

    # Assemble git args, honoring the optional shallow-clone knob.
    local -a clone_args=(clone)
    if [ -n "${CLONE_DEPTH}" ]; then
        clone_args+=(--depth "${CLONE_DEPTH}" --single-branch)
    fi
    clone_args+=("${REPO_URL}" "${clone_target}")

    local attempt=1
    while [ "${attempt}" -le "${CLONE_MAX_ATTEMPTS}" ]; do
        if sudo -u "${USER_NAME}" git "${clone_args[@]}" >>"${CLONE_LOG}" 2>&1; then
            echo "[github-clone] cloned ${REPO_URL} -> ${clone_target}" >>"${CLONE_LOG}"
            return 0
        fi
        echo "[github-clone] clone of ${REPO_URL} failed (attempt ${attempt}/${CLONE_MAX_ATTEMPTS})" >>"${CLONE_LOG}"
        # Remove the partial checkout so the retry (and next boot) starts clean.
        # Safe to rm: the guards above guarantee clone_target is a single path
        # component under WORKSPACE_DIR that did not pre-exist, so whatever is
        # here now was created by this attempt.
        rm -rf "${clone_target}"
        attempt=$((attempt + 1))
        if [ "${attempt}" -le "${CLONE_MAX_ATTEMPTS}" ]; then
            # Sleep base..2*base seconds. The jitter de-synchronizes retries so
            # a shared cause (network blip, rate-limit) doesn't make every repo
            # retry in lockstep. RANDOM is reseeded per subshell, so concurrent
            # workers draw different values.
            sleep "$(( CLONE_RETRY_DELAY + (RANDOM % (CLONE_RETRY_DELAY + 1)) ))"
        fi
    done
    echo "[github-clone] ERROR: giving up on ${REPO_URL} after ${CLONE_MAX_ATTEMPTS} attempts" >>"${CLONE_LOG}"
    # Record the permanent failure for the parent to tally. marker_id is a
    # per-repo index (not a PID), so markers never collide even if the OS
    # recycles a finished worker's PID later in the run.
    printf '%s\n' "${REPO_URL}" >"${FAIL_DIR}/${marker_id}"
    return 1
}

IFS='|' read -r -a _ra_repo_urls <<<"${RA_PLUGIN_GITHUB_REPO_URLS:-}"

# Directory where workers drop a marker per permanently-failed repo. Tallied
# after the pool drains; cleaned up on exit.
FAIL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ra-github-clone.XXXXXX")"
trap 'rm -rf "${FAIL_DIR}"; mark_done' EXIT

# Bounded worker pool: at most CLONE_JOBS clones run at once. Mental model is
# "CLONE_JOBS workers draining the queue of URLs" — wall-clock stays predictable
# and resource use bounded whether there are 3 repos or 300. When the cap is
# reached, `wait -n` blocks until one worker finishes, freeing a slot.
_ra_idx=0
for REPO_URL in "${_ra_repo_urls[@]}"; do
    [ -z "${REPO_URL}" ] && continue
    while [ "$(jobs -rp | wc -l)" -ge "${CLONE_JOBS}" ]; do
        wait -n 2>/dev/null || true
    done
    _ra_idx=$((_ra_idx + 1))
    clone_one "${REPO_URL}" "${_ra_idx}" &
done
wait  # drain the remaining workers

# Tally failures from the marker directory (see clone_one). Avoids per-PID wait
# bookkeeping, which is unreliable once `wait -n` has already reaped jobs.
failed=0
for _f in "${FAIL_DIR}"/*; do
    [ -e "${_f}" ] || continue  # no matches -> literal glob; skip
    failed=$((failed + 1))
    log "clone failed: $(cat "${_f}")"
done
unset _ra_repo_urls _f _ra_idx

if [ "${failed}" -gt 0 ]; then
    log "first-boot clone finished with ${failed} failed repo(s); see ${CLONE_LOG}"
else
    log "first-boot clone finished; all repos cloned"
fi
