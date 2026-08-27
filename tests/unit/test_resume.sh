#!/usr/bin/env bash
# P2.10: recovery/resume. Fabricates a run journal at a specific
# pre-interruption state (rather than actually killing a real process mid-
# flight, which tests/unit/test_proc_timeout.sh already covers at the
# mechanism level) and exercises lib/resume.sh's entry-point decision and
# actual re-entry against the mock dsh. No LLM quota used.
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
export AGENT_STATE_HOME="$TMP/state"

new_fixture_run() {
  # Creates a fresh git repo fixture + a CREATED-state run journal for it.
  # Prints "workspace_dir<TAB>run_dir<TAB>run_id".
  local name="$1" ws run_id run_dir head
  ws="$TMP/$name"
  make_node_fixture "$ws"
  head="$(git -C "$ws" rev-parse HEAD)"
  run_id="$(run_id_generate)"
  run_dir="$(journal_run_create "$ws" "$run_id" "Add validation to prevent negative numbers." "$head" "false")"
  git_safety_snapshot "$ws" "$run_dir"
  printf '%s\t%s\t%s\n' "$ws" "$run_dir" "$run_id"
}

# ============================================================
# 1) Entry-point decision logic (pure, no dsh calls)
# ============================================================
IFS=$'\t' read -r ws1 run_dir1 run_id1 <<< "$(new_fixture_run decision1)"
assert_eq "context" "$(resume_entry_decision "$run_dir1")" "CREATED state resumes at 'context'"

journal_run_transition "$run_dir1" CONTEXT
assert_eq "context" "$(resume_entry_decision "$run_dir1")" "CONTEXT state resumes at 'context'"

journal_run_transition "$run_dir1" IMPLEMENTING
assert_eq "context" "$(resume_entry_decision "$run_dir1")" "IMPLEMENTING with no in-flight lead call is safe to restart"

journal_event_emit "$run_dir1" "lead.started" "provider=lead" "attempt=1"
assert_eq "uncertain" "$(resume_entry_decision "$run_dir1")" "IMPLEMENTING with an in-flight (unfinished) lead call is UNCERTAIN"
journal_event_emit "$run_dir1" "lead.completed" "attempt=1"
assert_eq "context" "$(resume_entry_decision "$run_dir1")" "once lead.completed is logged, it's no longer in flight"

journal_run_transition "$run_dir1" VALIDATING
assert_eq "validating" "$(resume_entry_decision "$run_dir1")" "VALIDATING resumes at 'validating'"

journal_run_transition "$run_dir1" REVIEWING
assert_eq "reviewing" "$(resume_entry_decision "$run_dir1")" "REVIEWING resumes at 'reviewing'"

journal_run_transition "$run_dir1" CORRECTING
assert_eq "correcting" "$(resume_entry_decision "$run_dir1")" "CORRECTING with no in-flight correction call resumes at 'correcting'"

journal_event_emit "$run_dir1" "correction.started" "provider=lead" "attempt=1"
assert_eq "uncertain" "$(resume_entry_decision "$run_dir1")" "CORRECTING with an in-flight correction call is UNCERTAIN (Scenario E)"

journal_run_update "$run_dir1" "interrupted_from_state=COMPLETED"
assert_eq "terminal" "$(resume_entry_decision "$run_dir1")" "a terminal interrupted_from_state resumes as 'terminal'"

# ============================================================
# 2) resume_run: already-terminal run -> no-op
# ============================================================
IFS=$'\t' read -r ws2 run_dir2 run_id2 <<< "$(new_fixture_run terminal2)"
journal_run_transition "$run_dir2" CONTEXT
journal_run_transition "$run_dir2" IMPLEMENTING
journal_run_transition "$run_dir2" VALIDATING
journal_run_transition "$run_dir2" COMPLETED
out2="$(resume_run "$run_id2")"
code2=$?
assert_eq "0" "$code2" "resuming an already-COMPLETED run exits 0"
assert_contains "$out2" "already COMPLETED" "resume reports the run is already finished, does nothing"

# ============================================================
# 3) resume_run: unknown run id
# ============================================================
err3=$(resume_run "no-such-run-id-12345" 2>&1 >/dev/null)
code3=$?
assert_eq "1" "$code3" "resuming an unknown run id fails"
assert_contains "$err3" "no such run" "the error names the problem"

# ============================================================
# 4) resume_run: git HEAD conflict -> refuses without --force
# ============================================================
IFS=$'\t' read -r ws4 run_dir4 run_id4 <<< "$(new_fixture_run conflict4)"
journal_run_transition "$run_dir4" CONTEXT
journal_run_transition "$run_dir4" IMPLEMENTING
journal_run_transition "$run_dir4" VALIDATING
# Simulate an external change to the repo after the run started.
echo "extra" >> "$ws4/NOTES.md"
git -C "$ws4" add -A >/dev/null 2>&1
git -C "$ws4" -c user.email=t@t.com -c user.name=t commit -q -m "external change" >/dev/null 2>&1

err4=$(resume_run "$run_id4" 2>&1 >/dev/null)
code4=$?
assert_eq "1" "$code4" "resume refuses when the git HEAD moved externally"
assert_contains "$err4" "moved since run" "the git conflict is reported clearly"

# ============================================================
# 5) resume_run: UNCERTAIN state -> refuses without --force
# ============================================================
IFS=$'\t' read -r ws5 run_dir5 run_id5 <<< "$(new_fixture_run uncertain5)"
journal_run_transition "$run_dir5" CONTEXT
journal_run_transition "$run_dir5" IMPLEMENTING
journal_event_emit "$run_dir5" "lead.started" "provider=lead" "attempt=1"
# workspace has an uncommitted (possibly half-written) change, matching a
# real "interrupted mid-implementation" scenario
echo "// half-written" >> "$ws5/add.js"

err5=$(resume_run "$run_id5" 2>&1 >/dev/null)
code5=$?
assert_eq "1" "$code5" "resume refuses an UNCERTAIN state without --force"
assert_contains "$err5" "UNCERTAIN" "the uncertainty is reported, not silently guessed past"

# ============================================================
# 6) resume_run: "validating" entry — implementation was done, resume
# re-runs validation and review, calling the reviewer only (never Claude
# again for implementation).
# ============================================================
IFS=$'\t' read -r ws6 run_dir6 run_id6 <<< "$(new_fixture_run validating6)"
journal_run_transition "$run_dir6" CONTEXT
journal_run_transition "$run_dir6" IMPLEMENTING
# Simulate that Claude's implementation already completed before the
# interruption: the fix is present, uncommitted.
cat > "$ws6/add.js" <<'EOF'
function add(a, b) {
  if (a < 0 || b < 0) {
    throw new Error('negative numbers are not allowed');
  }
  return a + b;
}
module.exports = { add };
EOF
journal_run_update "$run_dir6" "last_completed_phase=IMPLEMENTATION_DONE"
journal_run_transition "$run_dir6" VALIDATING

use_mock_dsh happy
out6="$(resume_run "$run_id6" 2>&1)"
code6=$?
assert_eq "0" "$code6" "resuming at 'validating' completes successfully"
assert_contains "$out6" "re-running validation" "resume at validating explicitly re-runs validation, not implementation"
assert_not_contains "$out6" "Step 1/6" "resume at validating never re-invokes the implementation step"
assert_contains "$out6" "FINAL RESULT: approved" "the resumed run reaches approval"
assert_eq "COMPLETED" "$(journal_run_get_state "$run_dir6")" "the journal reflects COMPLETED after a successful resume"

# ============================================================
# 7) resume_run: "reviewing" entry — validation was already done, resume
# calls the reviewer directly (skips validation AND implementation).
# ============================================================
IFS=$'\t' read -r ws7 run_dir7 run_id7 <<< "$(new_fixture_run reviewing7)"
journal_run_transition "$run_dir7" CONTEXT
journal_run_transition "$run_dir7" IMPLEMENTING
cat > "$ws7/add.js" <<'EOF'
function add(a, b) {
  if (a < 0 || b < 0) {
    throw new Error('negative numbers are not allowed');
  }
  return a + b;
}
module.exports = { add };
EOF
journal_run_update "$run_dir7" "last_completed_phase=IMPLEMENTATION_DONE"
journal_run_transition "$run_dir7" VALIDATING
printf '{"commands":["npm test"],"passed":["npm test"],"failed":[],"skipped":[]}' > "$run_dir7/validation.json"
journal_run_update "$run_dir7" "last_completed_phase=VALIDATION_DONE"
journal_run_transition "$run_dir7" REVIEWING

use_mock_dsh happy
out7="$(resume_run "$run_id7" 2>&1)"
code7=$?
assert_eq "0" "$code7" "resuming at 'reviewing' completes successfully"
assert_contains "$out7" "skipping re-validation" "resume at reviewing explicitly skips re-running validation"
assert_not_contains "$out7" "Step 2/6" "resume at reviewing never re-invokes the validation step"
assert_contains "$out7" "FINAL RESULT: approved" "the resumed run reaches approval"

# ============================================================
# 8) resume_run: "correcting" entry — Codex already returned findings,
# resume sends them straight to Claude (no re-review of the same round).
# ============================================================
IFS=$'\t' read -r ws8 run_dir8 run_id8 <<< "$(new_fixture_run correcting8)"
journal_run_transition "$run_dir8" CONTEXT
journal_run_transition "$run_dir8" IMPLEMENTING
# Implementation attempt left the workspace WITHOUT the negative-number
# guard yet (round 1 was incomplete) — this is exactly what the stored
# review already found.
journal_run_update "$run_dir8" "last_completed_phase=IMPLEMENTATION_DONE"
journal_run_transition "$run_dir8" VALIDATING
printf '{"commands":["npm test"],"passed":[],"failed":["npm test"],"skipped":[]}' > "$run_dir8/validation.json"
journal_run_update "$run_dir8" "last_completed_phase=VALIDATION_DONE" "risk=medium"
journal_run_transition "$run_dir8" REVIEWING
cat > "$run_dir8/review-1.json" <<'EOF'
{"verdict":"changes_requested","summary":"Missing validation.","findings":[{"severity":"high","category":"correctness","file":"add.js","line":1,"problem":"No negative-number check","reason":"Task requires rejecting negative inputs","recommendation":"Add a guard clause"}]}
EOF
journal_run_update "$run_dir8" "last_completed_phase=REVIEW_DONE"
journal_run_transition "$run_dir8" CORRECTING

use_mock_dsh resume_correction_fix
out8="$(resume_run "$run_id8" 2>&1)"
code8=$?
assert_eq "0" "$code8" "resuming at 'correcting' completes successfully"
assert_contains "$out8" "were already returned" "resume at correcting reports reusing the stored findings"
assert_contains "$out8" "Applied the fix during resumed correction" "Claude's correction call actually ran"
assert_contains "$out8" "FINAL RESULT: approved" "the second (fresh) review approves after correction"
assert_eq "1" "$([ -f "$ws8/add.js" ] && grep -c 'negative numbers are not allowed' "$ws8/add.js")" "the workspace now has the fix applied by the resumed correction"

# ============================================================
# 9) resume_run: --force on an UNCERTAIN state proceeds to validation
# ============================================================
IFS=$'\t' read -r ws9 run_dir9 run_id9 <<< "$(new_fixture_run forceduncertain9)"
journal_run_transition "$run_dir9" CONTEXT
journal_run_transition "$run_dir9" IMPLEMENTING
journal_event_emit "$run_dir9" "lead.started" "provider=lead" "attempt=1"
cat > "$ws9/add.js" <<'EOF'
function add(a, b) {
  if (a < 0 || b < 0) {
    throw new Error('negative numbers are not allowed');
  }
  return a + b;
}
module.exports = { add };
EOF

use_mock_dsh happy
out9="$(resume_run "$run_id9" true 2>&1)"
code9=$?
assert_eq "0" "$code9" "forcing past an UNCERTAIN state can still succeed"
assert_contains "$out9" "forced" "the forced override is acknowledged in the output"

# ============================================================
# 10) Workspace locking during resume: a run already locked elsewhere is
# refused, matching the fresh-run behavior.
# ============================================================
IFS=$'\t' read -r ws10 run_dir10 run_id10 <<< "$(new_fixture_run locked10)"
journal_run_transition "$run_dir10" CONTEXT
journal_run_transition "$run_dir10" IMPLEMENTING
journal_run_transition "$run_dir10" VALIDATING
workspace_lock_acquire "$ws10" "some-other-run-id"
out10=$(resume_run "$run_id10" 2>&1)
code10=$?
assert_eq "1" "$code10" "resume is refused while another run holds the workspace lock"
assert_contains "$out10" "another run is already active" "the lock conflict is reported clearly"
workspace_lock_release "$ws10" "some-other-run-id"

report_and_exit
