#!/bin/bash
# claude-sync tests: run the real pull script and push loop against a fake
# GCS (tests/fake-bin/gcloud) and fake metadata (tests/fake-bin/curl), each
# scenario in its own scratch dir. No root, no network, no real bucket.
#
#   bash claude-sync/tests/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "${HERE}")"
PULL="${PLUGIN}/workstation-startup.d/270_claude-sync-pull.sh"
DAEMON="${PLUGIN}/workstation-startup.d/271_claude-sync-daemon.sh"
TOOLS="${PLUGIN}/Dockerfile.d/110_claude-sync-tools.sh"

# A real workstation exports the live plugin config; never let it leak in.
for v in $(compgen -v RA_PLUGIN_CLAUDE_SYNC_) $(compgen -v RA_CLAUDE_SYNC_); do unset "${v}"; done
export PATH="${HERE}/fake-bin:${PATH}"

NS="proj-config-0000aaaa"
BUCKET="test-bucket"
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null; then ok "${desc}"; else bad "${desc}"; fi; }

# Fresh sandbox: fake GCS, a home, run dir, log, and the installed lib + loop.
setup() {
    T="$(mktemp -d)"
    export FAKE_GCS="${T}/gcs" FAKE_INSTANCE_NAME="workstations-aaaa"
    export RA_CLAUDE_SYNC_USER_HOME="${T}/home"
    export RA_CLAUDE_SYNC_LOG_FILE="${T}/sync.log"
    export RA_CLAUDE_SYNC_RUN_DIR="${T}/run"
    export RA_CLAUDE_SYNC_PID_FILE="${T}/run/loop.pid"
    export RA_CLAUDE_SYNC_LIB="${T}/lib/lib.sh"
    export RA_CLAUDE_SYNC_ENV_FILE="${T}/env"
    export RA_CLAUDE_SYNC_PULL_DETACHED=1
    mkdir -p "${FAKE_GCS}/${BUCKET}" "${T}/home/.claude" "${T}/run"
    cat > "${T}/env" <<EOF
RA_PLUGIN_CLAUDE_SYNC_ENABLED=true
RA_PLUGIN_CLAUDE_SYNC_BUCKET=${BUCKET}
RA_PLUGIN_CLAUDE_SYNC_NAMESPACE=${NS}
RA_PLUGIN_CLAUDE_SYNC_INTERVAL_SECONDS=60
EOF
    RA_CLAUDE_SYNC_LIB_DIR="${T}/lib" bash "${TOOLS}" 2>/dev/null
    RA_CLAUDE_SYNC_BIN_DIR="${T}/bin" RA_CLAUDE_SYNC_INSTALL_ONLY=1 bash "${DAEMON}"
    LOOP="${T}/bin/ra-claude-sync-loop.sh"
}
teardown() { [ -n "${KEEP:-}" ] && { echo "  (kept ${T})"; return; }; rm -rf "${T}"; }

ns_dir() { echo "${FAKE_GCS}/${BUCKET}/claude-sync/workstations/$1"; }
put_manifest() { # $1 = ns, $2 = epoch, $3 = writer
    mkdir -p "${FAKE_GCS}/${BUCKET}/claude-sync/_manifest"
    printf '{"last_push_at_epoch": %s, "writer": "%s"}\n' "$2" "${3:-}" \
        > "${FAKE_GCS}/${BUCKET}/claude-sync/_manifest/$1.json"
}
put_file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
lines() { wc -l < "$1" | tr -d ' '; }
log_has() { grep -q -- "$1" "${RA_CLAUDE_SYNC_LOG_FILE}"; }
status_is() { [ "$(jq -r .state "${RA_CLAUDE_SYNC_RUN_DIR}/pull.json")" = "$1" ]; }

echo "1. rebuild: own namespace restores into an empty home, exempt from age/cap"
setup
own="$(ns_dir "${NS}")"
put_file "${own}/projects/-p/s1.jsonl" '{"t":1}'
put_file "${own}/projects/-p/s2.jsonl" '{"t":2}'
put_file "${own}/plans/plan.md" 'plan'
put_file "${own}/history.jsonl" '{"display":"old prompt","timestamp":10}'
put_file "${own}/claude.json" '{"projects":{"/p":{"history":[{"display":"old prompt"}]}}}'
put_manifest "${NS}" 1 workstations-dead     # far beyond the 30d TTL
put_file "$(ns_dir stale-other)/projects/-q/x.jsonl" '{"t":3}'
put_manifest stale-other 1
put_file "$(ns_dir fresh-other)/projects/-r/y.jsonl" '{"t":4}'
put_manifest fresh-other "$(date -u +%s)"
echo '{"numStartups":1,"projects":{}}' > "${T}/home/.claude.json"
bash "${PULL}" >/dev/null 2>&1
check "own transcripts restored" test -f "${T}/home/.claude/projects/-p/s2.jsonl"
check "own plans restored" test -f "${T}/home/.claude/plans/plan.md"
check "fresh other namespace merged" test -f "${T}/home/.claude/projects/-r/y.jsonl"
check "stale other namespace still skipped" test ! -e "${T}/home/.claude/projects/-q"
check "history.jsonl restored" grep -q 'old prompt' "${T}/home/.claude/history.jsonl"
check ".claude.json gains project history, keeps local fields" \
    jq -e '.numStartups == 1 and (.projects["/p"].history | length) == 1' "${T}/home/.claude.json"
check "log says own namespace included" log_has "include ${NS}: own namespace"
check "pull.json done with 4 files restored" \
    jq -e '.state == "done" and .files_restored == 4 and .namespaces == 2' "${RA_CLAUDE_SYNC_RUN_DIR}/pull.json"
teardown

echo "2. local files always win over the remote copy"
setup
put_file "$(ns_dir "${NS}")/projects/-p/s1.jsonl" 'REMOTE'
put_file "${T}/home/.claude/projects/-p/s1.jsonl" 'LOCAL'
bash "${PULL}" >/dev/null 2>&1
check "local transcript untouched" grep -qx LOCAL "${T}/home/.claude/projects/-p/s1.jsonl"
teardown

echo "3. pull failure is recorded, not left as running"
setup
rm -f "${RA_CLAUDE_SYNC_LIB}"
bash "${PULL}" >/dev/null 2>&1
check "pull.json failed when lib is missing" status_is failed
teardown

echo "4. two writers on one namespace converge on the union"
setup
A="${T}/home"; B="${T}/homeB"
mkdir -p "${B}/.claude"
put_file "${A}/.claude/history.jsonl" '{"display":"from A","timestamp":1}'
put_file "${B}/.claude/history.jsonl" '{"display":"from B","timestamp":2}'
echo '{"projects":{"/a":{"history":[{"display":"from A"}]}}}' > "${A}/.claude.json"
echo '{"projects":{"/b":{"history":[{"display":"from B"}]}}}' > "${B}/.claude.json"
FAKE_INSTANCE_NAME=ws-a RA_CLAUDE_SYNC_USER_HOME="${A}" bash "${LOOP}" --once >/dev/null 2>&1
FAKE_INSTANCE_NAME=ws-b RA_CLAUDE_SYNC_USER_HOME="${B}" bash "${LOOP}" --once >/dev/null 2>&1
FAKE_INSTANCE_NAME=ws-a RA_CLAUDE_SYNC_USER_HOME="${A}" bash "${LOOP}" --once >/dev/null 2>&1
own="$(ns_dir "${NS}")"
check "remote history.jsonl holds both writers' prompts" test "$(lines "${own}/history.jsonl")" -eq 2
check "remote claude.json holds both projects' history" \
    jq -e '(.projects["/a"].history | length) == 1 and (.projects["/b"].history | length) == 1' "${own}/claude.json"
check "local .claude.json is not modified by a push" jq -e '.projects | has("/b") | not' "${A}/.claude.json"
check "shared-writer WARN logged" log_has "shared with live writer ws-b"
check "manifest records writer" jq -e '.writer == "ws-a"' "${FAKE_GCS}/${BUCKET}/claude-sync/_manifest/${NS}.json"
teardown

echo "5. a lost upload race re-reads and keeps the racer's write"
setup
put_file "${T}/home/.claude/history.jsonl" '{"display":"mine","timestamp":5}'
export FAKE_GCS_RACE_MARKER="${T}/race"; touch "${FAKE_GCS_RACE_MARKER}"
bash "${LOOP}" --once >/dev/null 2>&1
unset FAKE_GCS_RACE_MARKER
own="$(ns_dir "${NS}")"
check "retry logged" log_has "lost a race"
check "racer line kept" grep -q racer "${own}/history.jsonl"
check "our line kept" grep -q mine "${own}/history.jsonl"
teardown

echo "6. the push loop waits for the boot pull"
setup
put_file "${T}/home/.claude/history.jsonl" '{"display":"x","timestamp":1}'
echo '{"state":"running"}' > "${RA_CLAUDE_SYNC_RUN_DIR}/pull.json"
manifest="${FAKE_GCS}/${BUCKET}/claude-sync/_manifest/${NS}.json"
bash "${LOOP}" >/dev/null 2>&1 &
loop_pid=$!
sleep 3
check "no push while pull is running" test ! -e "${manifest}"
echo '{"state":"done"}' > "${RA_CLAUDE_SYNC_RUN_DIR}/pull.json"
for _ in $(seq 1 30); do [ -e "${manifest}" ] && break; sleep 0.5; done
check "first push after pull finishes" test -e "${manifest}"
check "wait logged" log_has "waiting for boot pull"
kill "${loop_pid}" 2>/dev/null; wait "${loop_pid}" 2>/dev/null
teardown

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
