#!/usr/bin/env bash
# P2.10: recovery/resume. Resume NEVER means continuing the same internal
# Claude/Codex/DSH session — those are one-shot by design (see
# docs/upstream-findings.md). It means: read OUR OWN journal, verify git
# state hasn't moved in a way we can't account for, identify the last SAFE
# checkpoint, and re-enter lib/orchestrate.sh's shared validate/review
# functions with a freshly-built, self-contained task — never a destructive
# git operation. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

# resume_entry_decision <run_dir>
# Prints one of: context | validating | reviewing | correcting | verifying
#               | terminal | uncertain
# Uses `interrupted_from_state` (set by lib/orchestrate.sh's interrupt trap)
# when present, else the run's current `state`. IMPLEMENTING/CORRECTING are
# only "uncertain" when lib/git_safety.sh's journal_call_in_flight proves
# that phase's own dsh call never logged completion — otherwise (the
# transition happened but the call itself hadn't started yet) it's safe to
# just (re)try that phase, per the spec's own worked examples.
resume_entry_decision() {
  local run_dir="$1" pre_state
  pre_state="$(journal_run_get_field "$run_dir" interrupted_from_state)"
  [ -z "$pre_state" ] && pre_state="$(journal_run_get_field "$run_dir" state)"

  case "$pre_state" in
    CREATED|CONTEXT)
      echo "context" ;;
    IMPLEMENTING)
      if [ "$(journal_call_in_flight "$run_dir" lead)" = "true" ]; then
        echo "uncertain"
      else
        echo "context"
      fi
      ;;
    VALIDATING) echo "validating" ;;
    REVIEWING) echo "reviewing" ;;
    CORRECTING)
      if [ "$(journal_call_in_flight "$run_dir" correction)" = "true" ]; then
        echo "uncertain"
      else
        echo "correcting"
      fi
      ;;
    VERIFYING) echo "verifying" ;;
    COMPLETED|FAILED|CANCELLED) echo "terminal" ;;
    *) echo "uncertain" ;;
  esac
}

# _resume_force_transition <run_dir> <target>
# Resuming can need to reach a state the normal forward flow never jumps to
# directly (e.g. CORRECTING -> REVIEWING when a stale review is being
# reused) — every state can reach INTERRUPTED, and INTERRUPTED can reach
# any in-flight phase, so that's the safe detour when a direct transition
# isn't itself part of the state machine's normal edges.
_resume_force_transition() {
  local run_dir="$1" target="$2" current
  current="$(journal_run_get_state "$run_dir")"
  [ "$current" = "$target" ] && return 0
  if run_state_can_transition "$current" "$target"; then
    journal_run_transition "$run_dir" "$target"
    return 0
  fi
  if run_state_can_transition "$current" INTERRUPTED; then
    journal_run_transition "$run_dir" INTERRUPTED
    journal_run_transition "$run_dir" "$target"
  fi
}

# resume_last_review_round <run_dir>
# Highest round number with a review-N.json already on disk, or empty.
# Used by the "correcting" entry — that review already came back before
# the interruption, so it's reused rather than re-asking Codex.
resume_last_review_round() {
  local run_dir="$1" f max=0 n
  for f in "$run_dir"/review-[0-9]*.json; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .json)"
    n="${n#review-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [ "$n" -gt "$max" ] && max="$n"
  done
  [ "$max" -gt 0 ] && echo "$max"
}

# resume_run <run_id> [force: true|false]
# The CLI-facing entry point (`agent resume <run-id>`). Returns 0/1 exactly
# like orchestrate_run; prints its own FINAL RESULT-shaped messages.
resume_run() {
  local run_id="$1" force="${2:-false}"
  local run_dir
  run_dir="$(run_cli_find_run_dir "$run_id")"
  if [ -z "$run_dir" ]; then
    echo "error: no such run: $run_id" >&2
    return 1
  fi

  local state
  state="$(journal_run_get_state "$run_dir")"
  if run_state_is_terminal "$state"; then
    echo "run $run_id is already $state — nothing to resume (see: agent show $run_id)"
    return 0
  fi

  local workspace
  workspace="$(journal_run_get_field "$run_dir" workspace)"
  if [ -z "$workspace" ] || [ ! -d "$workspace" ]; then
    echo "error: the workspace recorded for run $run_id is missing or no longer exists: ${workspace:-<none recorded>}" >&2
    return 1
  fi

  if git_safety_head_conflict "$run_dir" "$workspace"; then
    if [ "$force" != "true" ]; then
      echo "error: the git branch HEAD has moved since run $run_id started (recorded $(journal_run_get_field "$run_dir" base_git_head), now $(git_safety_current_head "$workspace")) — something changed this repo outside the agent. Refusing to resume automatically." >&2
      echo "  Inspect $workspace yourself, then either: start a new run, or re-run with force to continue anyway (no automatic reset/checkout is ever performed)." >&2
      return 1
    fi
    echo "warning: proceeding despite a git HEAD conflict (forced)." >&2
  fi

  local decision
  decision="$(resume_entry_decision "$run_dir")"

  if [ "$decision" = "uncertain" ]; then
    if [ "$force" != "true" ]; then
      echo "run $run_id was interrupted while Claude was actively editing (implementation or correction in flight) — the workspace state is UNCERTAIN, not proven safe." >&2
      echo "  Refusing to blindly continue. Inspect $workspace yourself, then either: finish/revert it manually and start a new run, or re-run with force to proceed to validation on the workspace as-is." >&2
      return 1
    fi
    echo "warning: resuming from an UNCERTAIN state (forced) — proceeding to validation on the current workspace as-is." >&2
    decision="validating"
  fi

  if ! workspace_lock_acquire "$workspace" "$run_id"; then
    echo "FINAL RESULT: error — another run is already active in this workspace." >&2
    return 1
  fi
  # See lib/orchestrate.sh's orchestrate_run for why this trap must be set
  # directly in this function's body (bash fires a RETURN trap on the
  # return of whichever function last called `trap`, not its caller).
  trap 'workspace_lock_release "$workspace" "$run_id" >/dev/null 2>&1 || true; trap - RETURN' RETURN

  journal_event_emit "$run_dir" "run.resumed" "from_decision=$decision" "forced=$force"
  local task
  task="$(cat "$run_dir/task.txt" 2>/dev/null || echo "")"
  local max_rounds
  max_rounds="$(orchestrate_max_rounds)"

  echo "resuming run $run_id (entry point: $decision)"

  case "$decision" in
    context)
      echo "nothing was safely completed yet — restarting from implementation."
      if run_state_can_transition "$(journal_run_get_state "$run_dir")" CONTEXT; then
        journal_run_transition "$run_dir" CONTEXT
      fi
      echo
      echo "== Step 0/6: gathering context (memory / graph / research) =="
      context_build "$workspace" "$task" "$run_dir/context.md"
      [ -s "$run_dir/context.md" ] || echo "(no automatic context was gathered — investigate normally.)" > "$run_dir/context.md"

      journal_run_transition "$run_dir" IMPLEMENTING "last_completed_phase=CONTEXT_READY"
      echo
      echo "== Step 1/6: Claude Code implements =="
      orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/lead.md" "TASK=$run_dir/task.txt" "CONTEXT=$run_dir/context.md" > "$run_dir/lead-message.txt"
      if ! orchestrate_call_dsh_tracked "$workspace" "$run_dir" lead "$run_dir/lead-message.txt" "$run_dir/lead-out.txt" claude lead; then
        _orchestrate_finish "$run_dir" "$workspace" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" implementation "could not reach the lead (Claude Code) profile"
        echo "FINAL RESULT: error — could not reach the lead (Claude Code) profile." >&2
        return 1
      fi
      cat "$run_dir/lead-out.txt"
      journal_run_update "$run_dir" "last_completed_phase=IMPLEMENTATION_DONE"

      local changed_files
      changed_files="$(project_git_changed_files "$workspace")"
      journal_run_transition "$run_dir" VALIDATING
      if [ -z "$changed_files" ]; then
        echo "FINAL RESULT: no files changed — nothing to validate or review."
        _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "no files changed"
        return 0
      fi
      _orchestrate_validate_and_review "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$changed_files" false
      return $?
      ;;

    validating)
      echo "implementation was already done — re-running validation on the current workspace."
      local changed_files
      changed_files="$(project_git_changed_files "$workspace")"
      if [ -z "$changed_files" ]; then
        echo "FINAL RESULT: no files changed — nothing to validate or review."
        _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "no files changed"
        return 0
      fi
      _orchestrate_validate_and_review "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$changed_files" false
      return $?
      ;;

    reviewing|verifying)
      echo "validation was already done — calling the reviewer fresh (skipping re-validation, nothing has changed since)."
      local changed_files
      changed_files="$(project_git_changed_files "$workspace")"
      if [ -z "$changed_files" ]; then
        echo "FINAL RESULT: no files changed — nothing to validate or review."
        _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "no files changed"
        return 0
      fi
      _resume_force_transition "$run_dir" REVIEWING
      _orchestrate_validate_and_review "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$changed_files" true
      return $?
      ;;

    correcting)
      local last_round
      last_round="$(resume_last_review_round "$run_dir")"
      if [ -z "$last_round" ]; then
        echo "warning: expected an existing review from before the interruption but found none — falling back to re-validating and reviewing from scratch." >&2
        local changed_files
        changed_files="$(project_git_changed_files "$workspace")"
        _orchestrate_validate_and_review "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$changed_files" false
        return $?
      fi
      echo "review findings from round $last_round were already returned — sending them to Claude for correction."
      local changed_files validation_json="$run_dir/validation.json"
      changed_files="$(project_git_changed_files "$workspace")"
      local risk_tier require_strict_approval=0
      risk_tier="$(journal_run_get_field "$run_dir" risk)"
      risk_requires_verification "${risk_tier:-medium}" && require_strict_approval=1
      _resume_force_transition "$run_dir" REVIEWING
      _orchestrate_review_loop "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$validation_json" "$require_strict_approval" "$changed_files" "$last_round" "$run_dir/review-$last_round.json"
      return $?
      ;;
  esac
}
