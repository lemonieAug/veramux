#!/usr/bin/env bash
# P2.19: failure-injection E2E scenarios, run through the real `bin/agent`
# CLI end to end (not by calling lib functions directly) against the mock
# dsh. Scenarios F/G/H (Graphify/claude-mem/Agent-Reach unavailable -> P1
# fallback works) are unchanged P1 behavior already covered by
# tests/unit/test_context.sh, test_graph.sh, and test_memory.sh — not
# duplicated here. No LLM quota used.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/project_config.sh"
source "$ROOT_DIR/lib/validation.sh"
source "$ROOT_DIR/lib/project_detect.sh"
source "$ROOT_DIR/lib/redact.sh"
source "$ROOT_DIR/lib/graph.sh"
source "$ROOT_DIR/lib/memory.sh"
source "$ROOT_DIR/lib/research.sh"
source "$ROOT_DIR/lib/context.sh"
source "$ROOT_DIR/lib/risk.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/journal.sh"
source "$ROOT_DIR/lib/failures.sh"
source "$ROOT_DIR/lib/proc_timeout.sh"
source "$ROOT_DIR/lib/retry.sh"
source "$ROOT_DIR/lib/workspace_lock.sh"
source "$ROOT_DIR/lib/git_safety.sh"
source "$ROOT_DIR/lib/run_cli.sh"
source "$ROOT_DIR/lib/orchestrate.sh"
source "$ROOT_DIR/lib/resume.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_id_from_output() {
  # `run: <id>` is the first line orchestrate_run prints.
  printf '%s' "$1" | grep -m1 '^run: ' | awk '{print $2}'
}

# ============================================================
# Scenario A: Claude (lead) process fails outright.
# Expected: FAILED, correct phase, journal intact, no orphan process.
# ============================================================
use_mock_dsh lead_unreachable
make_node_fixture "$TMP/scenA"
outA="$(run_agent "$TMP/scenA" "task" 2>&1)"
codeA=$?
run_idA="$(run_id_from_output "$outA")"
assert_eq "1" "$codeA" "Scenario A: lead failure is a run failure, not success"
assert_contains "$outA" "could not reach the lead" "Scenario A: clear message"
assert_eq "1" "$([ -n "$run_idA" ] && echo 1 || echo 0)" "Scenario A: a run id was still recorded"
if [ -n "$run_idA" ]; then
  run_dirA="$(run_cli_find_run_dir "$run_idA")"
  assert_eq "FAILED" "$(journal_run_get_state "$run_dirA")" "Scenario A: journal state is FAILED"
  assert_contains "$(cat "$run_dirA/final.json" 2>/dev/null)" '"status":"failed"' "Scenario A: final.json records failure"
  assert_eq "1" "$([ -f "$run_dirA/events.jsonl" ] && [ -s "$run_dirA/events.jsonl" ] && echo 1 || echo 0)" "Scenario A: events.jsonl is intact and non-empty"
fi

# ============================================================
# Scenario B: the lead call never returns on its own (a hung child).
# Expected: TIMEOUT (our own deadline, not dsh's), no false success, and
# the hung process is actually gone afterward (no orphan).
# ============================================================
use_mock_dsh hang
export HANG_PID_FILE="$TMP/hang.pid"
export AGENT_TIMEOUT_OVERRIDE_CLAUDE=2
export AGENT_TIMEOUT_OVERRIDE_GRACE=1
make_node_fixture "$TMP/scenB"
start_ts=$(date +%s)
outB="$(run_agent "$TMP/scenB" "task" 2>&1)"
codeB=$?
elapsed=$(( $(date +%s) - start_ts ))
unset AGENT_TIMEOUT_OVERRIDE_CLAUDE AGENT_TIMEOUT_OVERRIDE_GRACE
run_idB="$(run_id_from_output "$outB")"
assert_eq "1" "$codeB" "Scenario B: a hung call is a failure, never a false success"
assert_eq "1" "$([ "$elapsed" -le 20 ] && echo 1 || echo 0)" "Scenario B: bounded by OUR timeout, not left hanging (elapsed=${elapsed}s)"
if [ -n "$run_idB" ]; then
  run_dirB="$(run_cli_find_run_dir "$run_idB")"
  assert_contains "$(cat "$run_dirB/final.json" 2>/dev/null)" '"category":"TIMEOUT"' "Scenario B: classified as TIMEOUT"
  assert_eq "FAILED" "$(journal_run_get_state "$run_dirB")" "Scenario B: journal state is FAILED"
fi
# Orphan check: the hung child's own PID must no longer be alive.
if [ -f "$HANG_PID_FILE" ]; then
  hang_pid="$(cat "$HANG_PID_FILE")"
  sleep 1
  if kill -0 "$hang_pid" 2>/dev/null; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: Scenario B: the hung process (pid $hang_pid) is still alive — orphaned" >&2
    kill -9 "$hang_pid" 2>/dev/null || true
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
else
  echo "SKIP: Scenario B orphan check — hang PID file was never written (mock didn't start in time)"
fi

# ============================================================
# Scenario C: Codex has no quota. Expected: review NOT approved, correct
# failure category (QUOTA), lead's own work is not blamed for it.
# ============================================================
use_mock_dsh quota_unavailable
make_node_fixture "$TMP/scenC"
outC="$(run_agent "$TMP/scenC" "task" 2>&1)"
codeC=$?
run_idC="$(run_id_from_output "$outC")"
assert_eq "1" "$codeC" "Scenario C: reviewer quota unavailable is a failure"
assert_not_contains "$outC" "FINAL RESULT: approved" "Scenario C: quota failure is never mistaken for approval"
if [ -n "$run_idC" ]; then
  run_dirC="$(run_cli_find_run_dir "$run_idC")"
  assert_contains "$(cat "$run_dirC/final.json" 2>/dev/null)" '"category":"QUOTA"' "Scenario C: classified as QUOTA, not a generic error"
  assert_contains "$(cat "$run_dirC/final.json" 2>/dev/null)" '"retryable":false' "Scenario C: QUOTA is never auto-retried"
fi

# ============================================================
# Scenario D (E2E via the real CLI): a run interrupted after implementation
# resumes at validation — never re-invoking Claude.
# ============================================================
use_mock_dsh happy
make_node_fixture "$TMP/scenD"
run_idD="$(run_id_generate)"
head_d="$(git -C "$TMP/scenD" rev-parse HEAD)"
run_dirD="$(journal_run_create "$TMP/scenD" "$run_idD" "Add validation to prevent negative numbers." "$head_d" "false")"
git_safety_snapshot "$TMP/scenD" "$run_dirD"
journal_run_transition "$run_dirD" CONTEXT
journal_run_transition "$run_dirD" IMPLEMENTING
cat > "$TMP/scenD/add.js" <<'EOF'
function add(a, b) {
  if (a < 0 || b < 0) {
    throw new Error('negative numbers are not allowed');
  }
  return a + b;
}
module.exports = { add };
EOF
journal_run_update "$run_dirD" "last_completed_phase=IMPLEMENTATION_DONE"
journal_run_transition "$run_dirD" VALIDATING
outD="$(bash "$ROOT_DIR/bin/agent" resume "$run_idD" 2>&1)"
codeD=$?
assert_eq "0" "$codeD" "Scenario D: resume via the real CLI completes successfully"
assert_contains "$outD" "re-running validation" "Scenario D: resume skips straight to validation"
assert_not_contains "$outD" "Step 1/6" "Scenario D: resume never re-invokes implementation"
assert_eq "COMPLETED" "$(journal_run_get_state "$run_dirD")" "Scenario D: journal ends COMPLETED"

# ============================================================
# Scenario I: two runs against the same workspace — the second is blocked.
# ============================================================
make_node_fixture "$TMP/scenI"
workspace_lock_acquire "$TMP/scenI" "holder-run"
use_mock_dsh happy
outI="$(run_agent "$TMP/scenI" "task" 2>&1)"
codeI=$?
assert_eq "1" "$codeI" "Scenario I: a second run against a locked workspace is blocked"
assert_contains "$outI" "another run is already active" "Scenario I: the conflict is reported clearly"
workspace_lock_release "$TMP/scenI" "holder-run"

# ============================================================
# P2.18 #23: a workspace that's already dirty BEFORE the run starts records
# dirty_at_start=true — so a later resume can tell the user's own
# pre-existing changes apart from what this run itself did.
# ============================================================
use_mock_dsh happy
make_node_fixture "$TMP/dirtystart"
echo "pre-existing uncommitted change" >> "$TMP/dirtystart/NOTES_PREEXISTING.md"
outDirty="$(run_agent "$TMP/dirtystart" "Add validation to prevent negative numbers." 2>&1)"
run_idDirty="$(run_id_from_output "$outDirty")"
if [ -n "$run_idDirty" ]; then
  run_dirDirty="$(run_cli_find_run_dir "$run_idDirty")"
  assert_eq "true" "$(journal_run_get_field "$run_dirDirty" dirty_at_start)" "a workspace already dirty at run start records dirty_at_start=true"
fi

make_node_fixture "$TMP/cleanstart"
outClean="$(run_agent "$TMP/cleanstart" "Add validation to prevent negative numbers." 2>&1)"
run_idClean="$(run_id_from_output "$outClean")"
if [ -n "$run_idClean" ]; then
  run_dirClean="$(run_cli_find_run_dir "$run_idClean")"
  assert_eq "false" "$(journal_run_get_field "$run_dirClean" dirty_at_start)" "a clean workspace at run start records dirty_at_start=false"

  # P2.3: the validation profile is assembled once at run start, persisted
  # run-scoped (for `agent show`/resume) and cached project-level, and its
  # metadata (never file contents) recorded as a structured event.
  assert_eq "1" "$([ -f "$run_dirClean/project-profile.json" ] && echo 1 || echo 0)" "P2.3: a run persists its own project-profile.json"
  assert_contains "$(cat "$run_dirClean/project-profile.json" 2>/dev/null)" '"package_manager":"npm"' "P2.3: the persisted profile resolved the package manager from the lockfile"
  assert_contains "$(run_cli_logs "$run_idClean" --json)" '"event":"project.detected"' "P2.3: project detection is a structured event"
  assert_not_contains "$(run_cli_logs "$run_idClean" --json | grep project.detected)" 'add.js' "P2.3: the project.detected event carries metadata, not file contents"
  assert_eq "1" "$([ -f "$(state_project_profile_cache "$TMP/cleanstart")" ] && echo 1 || echo 0)" "P2.3: the profile is also cached project-level for reuse across runs"
  assert_contains "$(run_cli_show "$run_idClean")" "project profile (P2.3)" "P2.3: agent show surfaces the profile"
fi

report_and_exit
