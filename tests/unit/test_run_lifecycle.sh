#!/usr/bin/env bash
# P2.4: run id generation + the run state machine.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
set +e

# --- run_id uniqueness ---
ids_file="$(mktemp)"
for _ in $(seq 1 200); do run_id_generate; done > "$ids_file"
total_lines="$(wc -l < "$ids_file" | tr -d ' ')"
unique_lines="$(sort -u "$ids_file" | wc -l | tr -d ' ')"
assert_eq "$total_lines" "$unique_lines" "200 generated run ids are all unique"
assert_contains "$(head -1 "$ids_file")" "T" "run id contains the ISO-ish timestamp separator"
rm -f "$ids_file"

first_id="$(run_id_generate)"
if [[ "$first_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]; then
  PASS_COUNT=$((PASS_COUNT + 1))
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: run id '$first_id' does not match YYYYMMDDTHHMMSSZ-xxxxxx" >&2
fi

# --- state validity ---
assert_exit_code "0" "CREATED is a valid state" run_state_is_valid CREATED
assert_exit_code "1" "BOGUS is not a valid state" run_state_is_valid BOGUS

# --- terminal states ---
assert_exit_code "0" "COMPLETED is terminal" run_state_is_terminal COMPLETED
assert_exit_code "0" "FAILED is terminal" run_state_is_terminal FAILED
assert_exit_code "0" "CANCELLED is terminal" run_state_is_terminal CANCELLED
assert_exit_code "1" "INTERRUPTED is not terminal (resumable)" run_state_is_terminal INTERRUPTED
assert_exit_code "1" "CREATED is not terminal" run_state_is_terminal CREATED

# --- valid transitions (the documented happy path) ---
assert_exit_code "0" "CREATED -> CONTEXT" run_state_can_transition CREATED CONTEXT
assert_exit_code "0" "CONTEXT -> IMPLEMENTING" run_state_can_transition CONTEXT IMPLEMENTING
assert_exit_code "0" "IMPLEMENTING -> VALIDATING" run_state_can_transition IMPLEMENTING VALIDATING
assert_exit_code "0" "VALIDATING -> REVIEWING" run_state_can_transition VALIDATING REVIEWING
assert_exit_code "0" "VALIDATING -> COMPLETED (low-risk skip-review path)" run_state_can_transition VALIDATING COMPLETED
assert_exit_code "0" "REVIEWING -> CORRECTING" run_state_can_transition REVIEWING CORRECTING
assert_exit_code "0" "REVIEWING -> COMPLETED (approved)" run_state_can_transition REVIEWING COMPLETED
assert_exit_code "0" "CORRECTING -> VALIDATING (re-validate after correction)" run_state_can_transition CORRECTING VALIDATING
assert_exit_code "0" "REVIEWING -> VERIFYING (high-risk verification pass)" run_state_can_transition REVIEWING VERIFYING
assert_exit_code "0" "VERIFYING -> COMPLETED" run_state_can_transition VERIFYING COMPLETED

# --- any non-terminal state can become INTERRUPTED or FAILED or CANCELLED ---
assert_exit_code "0" "IMPLEMENTING -> INTERRUPTED" run_state_can_transition IMPLEMENTING INTERRUPTED
assert_exit_code "0" "VALIDATING -> FAILED" run_state_can_transition VALIDATING FAILED
assert_exit_code "0" "REVIEWING -> CANCELLED" run_state_can_transition REVIEWING CANCELLED

# --- resume: INTERRUPTED can re-enter any in-flight phase ---
assert_exit_code "0" "INTERRUPTED -> VALIDATING (resume mid-flow)" run_state_can_transition INTERRUPTED VALIDATING
assert_exit_code "0" "INTERRUPTED -> IMPLEMENTING (resume mid-flow)" run_state_can_transition INTERRUPTED IMPLEMENTING

# --- invalid / structurally impossible transitions ---
assert_exit_code "1" "CREATED cannot jump straight to COMPLETED" run_state_can_transition CREATED COMPLETED
assert_exit_code "1" "CREATED cannot jump straight to REVIEWING" run_state_can_transition CREATED REVIEWING
assert_exit_code "1" "a terminal state (COMPLETED) cannot transition anywhere" run_state_can_transition COMPLETED CONTEXT
assert_exit_code "1" "a terminal state (FAILED) cannot transition anywhere" run_state_can_transition FAILED CONTEXT
assert_exit_code "1" "unknown target state is rejected" run_state_can_transition CREATED BOGUS
assert_exit_code "1" "unknown source state is rejected" run_state_can_transition BOGUS CONTEXT

report_and_exit
