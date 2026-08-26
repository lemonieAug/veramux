#!/usr/bin/env bash
# The deterministic Claude -> validate -> Codex -> correct loop (P0.7/P0.8).
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_ROOT_DIR="$(cd "$_ORCH_LIB_DIR/.." && pwd)"

orchestrate_max_rounds() {
  grep '^max_correction_rounds:' "$_ORCH_ROOT_DIR/policies/orchestration.yaml" | awk '{print $2}'
}

# DSH treats its invoking directory as the session workspace, and the
# Claude/Codex subagent's own cwd is derived from that (see
# docs/upstream-findings.md) — so every dsh call MUST run from inside the
# target project, regardless of where `agent` itself was invoked from. The
# subshell `cd` never affects the caller's own working directory.
orchestrate_call_dsh() {
  local workspace="$1" profile="$2" message_file="$3"
  ( cd "$workspace" && dsh --profile "$profile" "$(cat "$message_file")" )
}

orchestrate_json() { node "$_ORCH_LIB_DIR/json-tools.mjs" "$@"; }
orchestrate_render() { node "$_ORCH_LIB_DIR/render-template.mjs" "$@"; }

# Split out so both the first review attempt and the one allowed retry
# share identical call/redirect semantics.
orchestrate_review_call() {
  local workspace="$1" message_file="$2" out_file="$3"
  ( cd "$workspace" && dsh --profile reviewer "$(cat "$message_file")" ) > "$out_file"
}

orchestrate_run_validation() {
  local workspace="$1" out_json="$2"
  local commands
  commands="$(validation_detect_commands "$workspace" false)"
  if [ -n "$commands" ]; then
    printf '%s\n' "$commands" | validation_run "$workspace" "$out_json"
  else
    printf '%s' '{"commands":[],"passed":[],"failed":[],"skipped":[]}' > "$out_json"
    return 0
  fi
}

# orchestrate_run <workspace> <task-text>
# Prints progress and the lead's final answer to stdout as it happens.
# Returns 0 when the loop reaches an approved/non-blocking end state, 1
# otherwise (reviewer unreachable/invalid twice, or a blocking finding
# survives the max correction rounds). Never turns a 1 into a 0.
orchestrate_run() {
  local workspace="$1" task="$2"
  local run_dir
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-run.XXXXXX")"
  echo "run artifacts: $run_dir"

  local max_rounds
  max_rounds="$(orchestrate_max_rounds)"

  printf '%s' "$task" > "$run_dir/task.txt"

  echo
  echo "== Step 1/6: Claude Code implements =="
  orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/lead.md" "TASK=$run_dir/task.txt" > "$run_dir/lead-message.txt"
  local lead_answer
  if ! lead_answer="$(orchestrate_call_dsh "$workspace" lead "$run_dir/lead-message.txt")"; then
    echo "FINAL RESULT: error — could not reach the lead (Claude Code) profile." >&2
    return 1
  fi
  printf '%s\n' "$lead_answer"

  if ! project_is_git_repo "$workspace"; then
    echo
    echo "FINAL RESULT: error — $workspace is not a git repository; cannot collect a diff to validate or review." >&2
    return 1
  fi

  local changed_files
  changed_files="$(project_git_changed_files "$workspace")"
  if [ -z "$changed_files" ]; then
    echo
    echo "FINAL RESULT: no files changed — nothing to validate or review."
    return 0
  fi

  echo
  echo "== Step 2/6: validation =="
  local validation_json="$run_dir/validation.json"
  orchestrate_run_validation "$workspace" "$validation_json" || true
  orchestrate_json validation-summary "$validation_json"
  echo

  if project_changes_are_docs_only "$workspace"; then
    echo
    echo "FINAL RESULT: only documentation changed — skipping Codex review per policy."
    return 0
  fi

  local round=0
  while :; do
    round=$((round + 1))
    echo
    echo "== Step 3/6: Codex review (round $round/$max_rounds) =="

    local diff_text
    diff_text="$(project_git_diff "$workspace")"
    printf '%s' "$diff_text" | redact_diff "$_ORCH_ROOT_DIR/policies/safety.yaml" > "$run_dir/diff.txt"
    printf '%s' "$task" > "$run_dir/objective.txt"
    printf '%s\n' "$changed_files" > "$run_dir/files.txt"
    orchestrate_json validation-summary "$validation_json" > "$run_dir/validation-summary.txt"

    orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/reviewer.md" \
      "OBJECTIVE=$run_dir/objective.txt" \
      "VALIDATION_SUMMARY=$run_dir/validation-summary.txt" \
      "FILES=$run_dir/files.txt" \
      "DIFF=$run_dir/diff.txt" \
      > "$run_dir/reviewer-message-$round.txt"

    local review_file="$run_dir/review-$round.json"
    if ! orchestrate_review_call "$workspace" "$run_dir/reviewer-message-$round.txt" "$run_dir/review-raw-$round.json"; then
      echo "FINAL RESULT: error — could not reach the reviewer (Codex) profile." >&2
      return 1
    fi

    if ! orchestrate_json validate-review "$run_dir/review-raw-$round.json" > "$review_file" 2>"$run_dir/review-error-$round.txt"; then
      echo "reviewer response did not match the required JSON contract; retrying once:"
      cat "$run_dir/review-error-$round.txt"
      {
        cat "$run_dir/reviewer-message-$round.txt"
        echo
        echo "---"
        echo "Your previous response did not match the required output format. Error:"
        cat "$run_dir/review-error-$round.txt"
        echo "Respond again with exactly one JSON object matching the required schema, nothing else."
      } > "$run_dir/reviewer-message-$round-retry.txt"

      if ! orchestrate_review_call "$workspace" "$run_dir/reviewer-message-$round-retry.txt" "$run_dir/review-raw-$round-retry.json"; then
        echo "FINAL RESULT: error — could not reach the reviewer (Codex) profile on retry." >&2
        return 1
      fi
      if ! orchestrate_json validate-review "$run_dir/review-raw-$round-retry.json" > "$review_file" 2>"$run_dir/review-error-$round-retry.txt"; then
        echo "FINAL RESULT: reviewer did not return a valid response after one retry. Reporting as failure, not success." >&2
        cat "$run_dir/review-error-$round-retry.txt" >&2
        return 1
      fi
    fi

    local verdict
    verdict="$(orchestrate_json review-verdict "$review_file")"
    echo "verdict: $verdict"
    orchestrate_json blocking-findings "$review_file" > "$run_dir/blocking-$round.json"
    local blocking_count
    blocking_count="$(orchestrate_json findings-count "$run_dir/blocking-$round.json")"

    if [ "$verdict" = "approved" ] || [ "$blocking_count" -eq 0 ]; then
      echo
      echo "FINAL RESULT: approved (round $round)."
      return 0
    fi

    echo "$blocking_count blocking finding(s):"
    orchestrate_json findings-text "$run_dir/blocking-$round.json"
    echo

    if [ "$round" -ge "$max_rounds" ]; then
      echo
      echo "FINAL RESULT: blocked — $blocking_count critical/high finding(s) remain after $max_rounds correction round(s). Stopping instead of masking this as success." >&2
      return 1
    fi

    echo
    echo "== Step 4/6: Claude correction (round $round) =="
    orchestrate_json findings-text "$run_dir/blocking-$round.json" > "$run_dir/findings-text-$round.txt"
    orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/lead-correction.md" \
      "TASK=$run_dir/task.txt" \
      "FINDINGS=$run_dir/findings-text-$round.txt" \
      "VALIDATION_SUMMARY=$run_dir/validation-summary.txt" \
      > "$run_dir/lead-correction-message-$round.txt"

    local correction_answer
    if ! correction_answer="$(orchestrate_call_dsh "$workspace" lead "$run_dir/lead-correction-message-$round.txt")"; then
      echo "FINAL RESULT: error — could not reach the lead (Claude Code) profile for correction." >&2
      return 1
    fi
    printf '%s\n' "$correction_answer"

    echo
    echo "== Step 5/6: re-run validation after correction (round $round) =="
    orchestrate_run_validation "$workspace" "$validation_json" || true
    orchestrate_json validation-summary "$validation_json"
    echo
    echo "== Step 6/6: review again =="
    # loop continues at the top with an incremented round
  done
}
