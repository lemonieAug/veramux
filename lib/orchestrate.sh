#!/usr/bin/env bash
# The deterministic Claude -> validate -> Codex -> correct loop (P0.7/P0.8),
# extended in P1 with automatic context gathering (lib/context.sh) and
# risk-adaptive review depth (lib/risk.sh, P1.9/P1.10), and in P2 with a
# durable run journal, structured events, timeouts/retries/cancellation, and
# workspace locking (P2.4-P2.13). Every P0/P1 user-visible message stays
# byte-for-byte the same; P2 additions are layered alongside them, not
# instead of them. The validation+review portion is split into its own
# functions so lib/resume.sh (P2.10) can re-enter mid-flow instead of
# duplicating this logic.
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_ROOT_DIR="$(cd "$_ORCH_LIB_DIR/.." && pwd)"
_ORCH_RUNTIME_POLICY="$_ORCH_ROOT_DIR/policies/runtime.yaml"

# Focused tests and embedders sometimes source this library directly instead
# of entering through bin/agent, which normally loads the provider helpers.
if ! declare -F provider_primary >/dev/null 2>&1; then
  # shellcheck source=lib/provider_fallback.sh
  source "$_ORCH_LIB_DIR/provider_fallback.sh"
fi

orchestrate_max_rounds() {
  grep '^max_correction_rounds:' "$_ORCH_ROOT_DIR/policies/orchestration.yaml" | awk '{print $2}'
}

orchestrate_json() { node "$_ORCH_LIB_DIR/json-tools.mjs" "$@"; }
orchestrate_render() { node "$_ORCH_LIB_DIR/render-template.mjs" "$@"; }

# orchestrate_call_dsh_tracked <workspace> <run_dir> <profile> <message_file>
#                               <out_file> <timeout_kind> <event_prefix>
# The one place every dsh call goes through. Layers P2.8 (wall-clock
# timeout, via lib/proc_timeout.sh — see docs/upstream-findings.md for why
# that wrapper, not DSH itself, owns the deadline), P2.9 (a bounded retry
# for the small "transient" category only), P2.6 (paired
# "<prefix>.started"/"<prefix>.completed|failed" events — also what P2.10's
# resume logic uses to tell "call never started"/"call finished" apart from
# "call was genuinely in flight when we got interrupted"), and P2.16/P2.11
# (the cancel-request marker always wins over a raced exit code). DSH treats
# its invoking directory as the session workspace (see
# docs/upstream-findings.md), so this always `cd`s into the target project
# first, regardless of where `agent` itself runs from; using `exec` inside
# the wrapper shell means the tracked PID IS dsh, not an intermediate shell.
# Sets ORCHESTRATE_LAST_FAILURE_CATEGORY; returns 0/1.
ORCHESTRATE_LAST_FAILURE_CATEGORY=""
ORCHESTRATE_LAST_RESPONDING_PROVIDER=""
ORCHESTRATE_PRIMARY_FAILURE_CATEGORY=""
ORCHESTRATE_FALLBACK_FAILURE_CATEGORY=""
_orchestrate_call_dsh_provider_tracked() {
  local workspace="$1" run_dir="$2" profile="$3" message_file="$4" out_file="$5" timeout_kind="$6" event_prefix="$7" relay_provider="$8"
  local timeout_s grace_s attempt=0 max_attempts message
  # AGENT_TIMEOUT_OVERRIDE_<KIND> / AGENT_TIMEOUT_OVERRIDE_GRACE let an
  # operator (or a failure-injection test — see tests/unit/test_failure_
  # injection.sh) shorten a deadline at runtime without editing
  # policies/runtime.yaml; unset by default, so normal operation is
  # entirely policy-file-driven.
  local override_var="AGENT_TIMEOUT_OVERRIDE_$(printf '%s' "$timeout_kind" | tr '[:lower:]' '[:upper:]')"
  timeout_s="${!override_var:-$(policy_get "$_ORCH_RUNTIME_POLICY" timeouts "$timeout_kind" 600)}"
  grace_s="${AGENT_TIMEOUT_OVERRIDE_GRACE:-$(policy_get_toplevel "$_ORCH_RUNTIME_POLICY" timeout_grace_seconds 10)}"
  max_attempts="$(retry_max_attempts transient)"
  local message_bytes
  message_bytes="$(wc -c < "$message_file")"

  # DSH headless receives the task as a single argv argument.
  # Keep a safe margin below Linux's per-argument limit.
  if [ "$message_bytes" -gt 100000 ]; then
    printf 'DSH prompt too large for argv: %s bytes (limit: 100000)\n' \
      "$message_bytes" > "$out_file"
    ORCHESTRATE_LAST_FAILURE_CATEGORY="INTERNAL"
    return 1
  fi

  message="$(cat "$message_file")"

  while :; do
    attempt=$((attempt + 1))
    journal_event_emit "$run_dir" "provider.attempt" "profile=$profile" "provider_attempt=$relay_provider" "attempt=$attempt" "configured=true"
    journal_event_emit "$run_dir" "${event_prefix}.started" "profile=$profile" "provider=$relay_provider" "attempt=$attempt"

    local code=0
    proc_call_with_timeout "$run_dir" "$timeout_s" "$grace_s" "$out_file" -- \
      bash -c '
        cd "$1"
        export VERAMUX_RELAY_PROVIDER="$4"
        case "$4" in
          deepseek) unset VERAMUX_OPENAI_API_KEY ;;
          openai) unset VERAMUX_DEEPSEEK_API_KEY ;;
          *) exit 2 ;;
        esac
        exec dsh --profile "$2" "$3"
      ' _ "$workspace" "$profile" "$message" "$relay_provider" || code=$?

    if proc_cancel_requested "$run_dir"; then
      ORCHESTRATE_LAST_FAILURE_CATEGORY="CANCELLED"
      journal_event_emit "$run_dir" "${event_prefix}.failed" "profile=$profile" "provider=$relay_provider" "category=CANCELLED" "attempt=$attempt"
      return 1
    fi

    if [ "$code" -eq 0 ]; then
      journal_event_emit "$run_dir" "${event_prefix}.completed" "profile=$profile" "provider=$relay_provider" "attempt=$attempt"
      journal_event_emit "$run_dir" "provider.responded" "profile=$profile" "responding_provider=$relay_provider" "attempt=$attempt"
      journal_run_update "$run_dir" "last_relay_provider=$relay_provider" "last_provider_profile=$profile"
      ORCHESTRATE_LAST_RESPONDING_PROVIDER="$relay_provider"
      ORCHESTRATE_LAST_FAILURE_CATEGORY=""
      return 0
    fi

    local combined category
    combined="$(cat "$out_file" 2>/dev/null || true)"
    category="$(failure_classify "$code" "$combined" "")"
    ORCHESTRATE_LAST_FAILURE_CATEGORY="$category"
    journal_event_emit "$run_dir" "${event_prefix}.failed" "profile=$profile" "provider=$relay_provider" "category=$category" "attempt=$attempt" "exit_code=$code"

    if retry_should_retry "$category" "$attempt" transient; then
      local backoff
      backoff="$(retry_backoff_seconds "$attempt")"
      echo "transient failure ($category) calling $profile — retrying in ${backoff}s (attempt $((attempt + 1))/$max_attempts)" >&2
      sleep "$backoff"
      continue
    fi
    return 1
  done
}

# Public DSH-call wrapper. Every call starts with DeepSeek. OpenAI is attempted
# only after the primary retry budget is exhausted and the resulting category
# is explicitly allowlisted by lib/provider_fallback.sh. A successful fallback
# is not sticky: the next invocation starts at DeepSeek again.
orchestrate_call_dsh_tracked() {
  local workspace="$1" run_dir="$2" profile="$3" message_file="$4" out_file="$5" timeout_kind="$6" event_prefix="$7"
  local primary fallback env_file primary_configured=true fallback_reason
  primary="$(provider_primary)"
  fallback="$(provider_fallback)"
  env_file="$(env_dsh_home)/.env"

  ORCHESTRATE_LAST_FAILURE_CATEGORY=""
  ORCHESTRATE_LAST_RESPONDING_PROVIDER=""
  ORCHESTRATE_PRIMARY_FAILURE_CATEGORY=""
  ORCHESTRATE_FALLBACK_FAILURE_CATEGORY=""

  journal_run_update "$run_dir" \
    "primary_provider=$primary" "fallback_triggered=false" \
    "primary_provider_error=null" "fallback_provider_error=null"
  journal_event_emit "$run_dir" "provider.primary_selected" "primary_provider=$primary" "profile=$profile"

  if provider_is_configured "$primary" "$env_file"; then
    if _orchestrate_call_dsh_provider_tracked "$workspace" "$run_dir" "$profile" "$message_file" "$out_file" "$timeout_kind" "$event_prefix" "$primary"; then
      return 0
    fi
  else
    primary_configured=false
    ORCHESTRATE_LAST_FAILURE_CATEGORY="PROVIDER_UNAVAILABLE"
    journal_event_emit "$run_dir" "provider.attempt" "profile=$profile" "provider_attempt=$primary" "attempt=0" "configured=false"
    journal_event_emit "$run_dir" "${event_prefix}.failed" "profile=$profile" "provider=$primary" "category=PROVIDER_UNAVAILABLE" "attempt=0"
  fi

  ORCHESTRATE_PRIMARY_FAILURE_CATEGORY="$ORCHESTRATE_LAST_FAILURE_CATEGORY"
  journal_run_update "$run_dir" "primary_provider_error=$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY"
  [ "$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" = "CANCELLED" ] && return 1

  if ! provider_fallback_is_eligible "$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" "$primary_configured"; then
    journal_event_emit "$run_dir" "provider.fallback_skipped" \
      "fallback_from=$primary" "fallback_to=$fallback" \
      "category=$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" "reason=not_eligible"
    return 1
  fi

  fallback_reason="$(provider_fallback_reason "$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" "$primary_configured")"
  journal_run_update "$run_dir" \
    "fallback_triggered=true" "fallback_from=$primary" \
    "fallback_to=$fallback" "fallback_reason=$fallback_reason"
  journal_event_emit "$run_dir" "provider.fallback_triggered" \
    "fallback_triggered=true" "fallback_from=$primary" \
    "fallback_to=$fallback" "fallback_reason=$fallback_reason" \
    "primary_error=$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" "profile=$profile"
  echo "relay fallback: $primary -> $fallback ($fallback_reason)" >&2

  if ! provider_is_configured "$fallback" "$env_file"; then
    ORCHESTRATE_FALLBACK_FAILURE_CATEGORY="CONFIGURATION"
    journal_event_emit "$run_dir" "provider.attempt" "profile=$profile" "provider_attempt=$fallback" "attempt=0" "configured=false"
    journal_event_emit "$run_dir" "${event_prefix}.failed" "profile=$profile" "provider=$fallback" "category=CONFIGURATION" "attempt=0"
    journal_run_update "$run_dir" "fallback_provider_error=CONFIGURATION"
    return 1
  fi

  if _orchestrate_call_dsh_provider_tracked "$workspace" "$run_dir" "$profile" "$message_file" "$out_file" "$timeout_kind" "$event_prefix" "$fallback"; then
    return 0
  fi
  ORCHESTRATE_FALLBACK_FAILURE_CATEGORY="$ORCHESTRATE_LAST_FAILURE_CATEGORY"
  journal_run_update "$run_dir" "fallback_provider_error=$ORCHESTRATE_FALLBACK_FAILURE_CATEGORY"
  return 1
}

# orchestrate_capture_project_profile <workspace> <run_dir>
# P2.3: assemble the validation profile once at run start and persist it —
# a run-scoped copy (project-profile.json, mode 600) for `agent show` and
# resume, plus a project-level cache (lib/state_paths.sh) reused across
# runs. Deterministic, no LLM. The emitted event carries only metadata
# (counts + resolved names), never file contents. Best-effort: a profile
# that can't be built must never block a run.
orchestrate_capture_project_profile() {
  local workspace="$1" run_dir="$2" profile_json
  command -v project_profile_build >/dev/null 2>&1 || return 0
  profile_json="$(project_profile_build "$workspace" 2>/dev/null || true)"
  [ -n "$profile_json" ] || return 0

  printf '%s\n' "$profile_json" > "$run_dir/project-profile.json"
  chmod 600 "$run_dir/project-profile.json" 2>/dev/null || true

  local cache
  cache="$(state_project_profile_cache "$workspace")"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  printf '%s\n' "$profile_json" > "$cache" 2>/dev/null || true

  local meta
  meta="$(node -e '
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"))
    const j = (a) => (a && a.length ? a.join(",") : "none")
    process.stdout.write([
      "languages=" + j(p.languages),
      "package_manager=" + (p.package_manager || "none"),
      "frameworks=" + j(p.frameworks),
      "validation_commands=" + String(Object.keys(p.validation || {}).length),
    ].join("\n"))
  ' <<< "$profile_json" 2>/dev/null || true)"
  if [ -n "$meta" ]; then
    local -a meta_args=()
    while IFS= read -r line; do [ -n "$line" ] && meta_args+=("$line"); done <<< "$meta"
    journal_event_emit "$run_dir" "project.detected" "${meta_args[@]}"
  fi
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

# One short line per tier, shown to the reviewer so it knows what triggered
# the classification without us re-deriving it in prose each time.
orchestrate_risk_description() {
  case "$1" in
    high) echo "HIGH — a changed path or diff line matched a sensitive pattern (auth, secrets, payments, migrations, sandboxing, process execution, or similar). Scrutinize regardless of diff size." ;;
    medium) echo "MEDIUM — an ordinary application-logic change. Standard review depth." ;;
    low) echo "LOW — every changed path matches a low-risk pattern (docs, formatting, etc.). Review was requested anyway (project override)." ;;
    *) echo "$1" ;;
  esac
}

# _orchestrate_finish <run_dir> <workspace> <final_state> <category> <phase> <message>
# Writes final.json (P2.7 failure shape for a non-COMPLETED finish, or a
# small success summary for COMPLETED) and transitions the journal. Every
# return path in orchestrate_run/_orchestrate_validate_and_review funnels
# through here so the journal is never left inconsistent with what
# actually happened.
_orchestrate_finish() {
  local run_dir="$1" final_state="$3" category="$4" phase="$5" message="$6" run_id
  run_id="$(journal_run_get_field "$run_dir" run_id)"
  if run_state_can_transition "$(journal_run_get_state "$run_dir")" "$final_state"; then
    journal_run_transition "$run_dir" "$final_state"
  fi
  if [ "$final_state" = "COMPLETED" ]; then
    local responding_provider
    responding_provider="$(journal_run_get_field "$run_dir" last_relay_provider 2>/dev/null || true)"
    orchestrate_json build-object "status=completed" "run_id=$run_id" "message=$message" \
      "responding_provider=$responding_provider" > "$run_dir/final.json"
  else
    local -a provider_errors=()
    [ -n "$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY" ] && provider_errors+=("primary_provider=deepseek" "primary_error=$ORCHESTRATE_PRIMARY_FAILURE_CATEGORY")
    [ -n "$ORCHESTRATE_FALLBACK_FAILURE_CATEGORY" ] && provider_errors+=("fallback_provider=openai" "fallback_error=$ORCHESTRATE_FALLBACK_FAILURE_CATEGORY")
    failure_result_json "$category" "$phase" "$message" "$run_id" "${provider_errors[@]}" > "$run_dir/final.json"
  fi
  chmod 600 "$run_dir/final.json" 2>/dev/null || true
}

# _orchestrate_review_loop <workspace> <run_dir> <run_id> <task> <max_rounds>
#                           <validation_json> <require_strict_approval>
#                           <changed_files> [start_round] [seed_review_file]
# Steps 3-6: the Codex review / Claude correction loop. When seed_review_file
# is non-empty, round `start_round`'s Codex call is SKIPPED — that review
# already came back (and is stored there) before an interruption — resuming
# straight into acting on its verdict (P2.10's "correcting" resume entry).
# Otherwise behaves exactly like the original single-function loop.
_orchestrate_review_loop() {
  local workspace="$1" run_dir="$2" run_id="$3" task="$4" max_rounds="$5"
  local validation_json="$6" require_strict_approval="$7" changed_files="$8"
  local start_round="${9:-1}" seed_review_file="${10:-}"
  local round=$((start_round - 1))

  while :; do
    round=$((round + 1))
    echo
    echo "== Step 3/6: Codex review (round $round/$max_rounds) =="

    local review_file="$run_dir/review-$round.json"

    if [ -n "$seed_review_file" ] && [ "$round" -eq "$start_round" ] && [ -f "$seed_review_file" ]; then
      echo "(resuming: reusing the review already returned before the interruption)"
      cp "$seed_review_file" "$review_file"
    else
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
        "RISK=$run_dir/risk.txt" \
        "ARCHITECTURE=$run_dir/architecture.txt" \
        > "$run_dir/reviewer-message-$round.txt"

      if ! orchestrate_call_dsh_tracked "$workspace" "$run_dir" reviewer "$run_dir/reviewer-message-$round.txt" "$run_dir/review-raw-$round.json" codex review; then
        if [ "$ORCHESTRATE_LAST_FAILURE_CATEGORY" = "CANCELLED" ]; then
          _orchestrate_finish "$run_dir" "$workspace" CANCELLED CANCELLED review "run cancelled during review"
          echo "FINAL RESULT: cancelled — run $run_id was cancelled during review." >&2
          return 1
        fi
        # A reviewer that policy requires MUST NOT silently become "approved"
        # just because it's unreachable (P2.11) — this stays a failure.
        _orchestrate_finish "$run_dir" "$workspace" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" review "could not reach the reviewer (Codex) profile"
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

        if ! orchestrate_call_dsh_tracked "$workspace" "$run_dir" reviewer "$run_dir/reviewer-message-$round-retry.txt" "$run_dir/review-raw-$round-retry.json" codex review; then
          if [ "$ORCHESTRATE_LAST_FAILURE_CATEGORY" = "CANCELLED" ]; then
            _orchestrate_finish "$run_dir" "$workspace" CANCELLED CANCELLED review "run cancelled during review"
            echo "FINAL RESULT: cancelled — run $run_id was cancelled during review." >&2
            return 1
          fi
          _orchestrate_finish "$run_dir" "$workspace" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" review "could not reach the reviewer (Codex) profile on retry"
          echo "FINAL RESULT: error — could not reach the reviewer (Codex) profile on retry." >&2
          return 1
        fi
        if ! orchestrate_json validate-review "$run_dir/review-raw-$round-retry.json" > "$review_file" 2>"$run_dir/review-error-$round-retry.txt"; then
          echo "FINAL RESULT: reviewer did not return a valid response after one retry. Reporting as failure, not success." >&2
          cat "$run_dir/review-error-$round-retry.txt" >&2
          _orchestrate_finish "$run_dir" "$workspace" FAILED MALFORMED_OUTPUT review "reviewer did not return a valid response after one retry"
          return 1
        fi
      fi
    fi
    journal_run_update "$run_dir" "last_completed_phase=REVIEW_DONE"

    local verdict
    verdict="$(orchestrate_json review-verdict "$review_file")"
    echo "verdict: $verdict"
    orchestrate_json blocking-findings "$review_file" > "$run_dir/blocking-$round.json"
    local blocking_count
    blocking_count="$(orchestrate_json findings-count "$run_dir/blocking-$round.json")"

    if [ "$verdict" = "approved" ] || [ "$blocking_count" -eq 0 ]; then
      echo
      local final_message
      if [ "$require_strict_approval" -eq 1 ] && [ "$verdict" != "approved" ]; then
        # HIGH risk (policies/risk.yaml review.high.verification): note the
        # nuance instead of silently equating "nothing blocking" with an
        # explicit approval — but still end the loop, since there is
        # nothing actionable left to send back for correction.
        echo "FINAL RESULT: approved (round $round) — HIGH risk: Codex did not use the word \"approved\", but reported no blocking finding after review; nothing actionable remains to correct."
        final_message="approved (round $round) — HIGH risk, no explicit approval word but nothing blocking"
      else
        echo "FINAL RESULT: approved (round $round)$([ "$require_strict_approval" -eq 1 ] && echo ", verified")."
        final_message="approved (round $round)"
      fi
      _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "$final_message"
      return 0
    fi

    echo "$blocking_count blocking finding(s):"
    orchestrate_json findings-text "$run_dir/blocking-$round.json"
    echo

    if [ "$round" -ge "$max_rounds" ]; then
      echo
      echo "FINAL RESULT: blocked — $blocking_count critical/high finding(s) remain after $max_rounds correction round(s). Stopping instead of masking this as success." >&2
      _orchestrate_finish "$run_dir" "$workspace" FAILED REVIEW_FAILURE review "$blocking_count blocking finding(s) remain after $max_rounds correction round(s)"
      return 1
    fi

    journal_run_transition "$run_dir" CORRECTING

    echo
    echo "== Step 4/6: Claude correction (round $round) =="
    orchestrate_json findings-text "$run_dir/blocking-$round.json" > "$run_dir/findings-text-$round.txt"
    orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/lead-correction.md" \
      "TASK=$run_dir/task.txt" \
      "FINDINGS=$run_dir/findings-text-$round.txt" \
      "VALIDATION_SUMMARY=$run_dir/validation-summary.txt" \
      > "$run_dir/lead-correction-message-$round.txt"

    if ! orchestrate_call_dsh_tracked "$workspace" "$run_dir" lead "$run_dir/lead-correction-message-$round.txt" "$run_dir/correction-out-$round.txt" claude correction; then
      if [ "$ORCHESTRATE_LAST_FAILURE_CATEGORY" = "CANCELLED" ]; then
        _orchestrate_finish "$run_dir" "$workspace" CANCELLED CANCELLED correction "run cancelled during correction"
        echo "FINAL RESULT: cancelled — run $run_id was cancelled during correction." >&2
        return 1
      fi
      _orchestrate_finish "$run_dir" "$workspace" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" correction "could not reach the lead (Claude Code) profile for correction"
      echo "FINAL RESULT: error — could not reach the lead (Claude Code) profile for correction." >&2
      return 1
    fi
    local correction_answer
    correction_answer="$(cat "$run_dir/correction-out-$round.txt")"
    printf '%s\n' "$correction_answer"
    journal_run_update "$run_dir" "last_completed_phase=CORRECTION_DONE" "correction_round=$round"

    journal_run_transition "$run_dir" VALIDATING

    echo
    echo "== Step 5/6: re-run validation after correction (round $round) =="
    journal_event_emit "$run_dir" "validation.started" "round=$round"
    orchestrate_run_validation "$workspace" "$validation_json" || true
    orchestrate_json validation-summary "$validation_json"
    echo
    journal_event_emit "$run_dir" "validation.completed" "round=$round"
    journal_run_update "$run_dir" "last_completed_phase=VALIDATION_DONE" "current_git_head=$(git_safety_current_head "$workspace")"
    echo "== Step 6/6: review again =="
    journal_run_transition "$run_dir" REVIEWING
    # loop continues at the top with an incremented round; seed_review_file
    # only ever applies to the very first iteration.
  done
}

# _orchestrate_validate_and_review <workspace> <run_dir> <run_id> <task>
#                                   <max_rounds> <changed_files>
#                                   [skip_validation:true|false]
# Step 2 (validation) through the review/correct loop. The one function
# both a fresh orchestrate_run and lib/resume.sh's "validating"/"reviewing"
# resume entries call — skip_validation=true reuses the existing
# run_dir/validation.json instead of re-running commands (safe only when
# nothing has changed the workspace since that validation ran, which is
# exactly the "reviewing"/"verifying" resume case).
_orchestrate_validate_and_review() {
  local workspace="$1" run_dir="$2" run_id="$3" task="$4" max_rounds="$5" changed_files="$6"
  local skip_validation="${7:-false}"
  local validation_json="$run_dir/validation.json"

  if [ "$skip_validation" != "true" ]; then
    echo
    echo "== Step 2/6: validation =="
    journal_event_emit "$run_dir" "validation.started"
    orchestrate_run_validation "$workspace" "$validation_json" || true
    orchestrate_json validation-summary "$validation_json"
    echo
    journal_event_emit "$run_dir" "validation.completed" \
      "passed_count=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(r.passed.length))' "$validation_json" 2>/dev/null || echo 0)" \
      "failed_count=$(node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(r.failed.length))' "$validation_json" 2>/dev/null || echo 0)"
    journal_run_update "$run_dir" "last_completed_phase=VALIDATION_DONE" "current_git_head=$(git_safety_current_head "$workspace")"
  fi

  local -a extra_high_paths
  mapfile -t extra_high_paths < <(project_config_extra_high_risk_paths "$workspace")
  local risk_tier
  risk_tier="$(risk_classify "$workspace" "${extra_high_paths[@]}")"
  echo "risk classification: $risk_tier"
  journal_run_update "$run_dir" "risk=$risk_tier"

  local force_review=0
  project_config_always_review "$workspace" && force_review=1

  if [ "$risk_tier" = "low" ] && [ "$force_review" -eq 0 ] && ! risk_requires_codex low; then
    echo
    echo "FINAL RESULT: low risk change — skipping Codex review per policy (policies/risk.yaml)."
    _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "low risk — review skipped"
    return 0
  fi

  local require_strict_approval=0
  risk_requires_verification "$risk_tier" && require_strict_approval=1

  orchestrate_risk_description "$risk_tier" > "$run_dir/risk.txt"
  : > "$run_dir/architecture.txt"
  if [ "$risk_tier" = "high" ]; then
    local arch_max
    arch_max="$(policy_get "$_ORCH_ROOT_DIR/policies/context.yaml" graph max_chars 8000)"
    if context_graph_enabled "$workspace" && graph_is_ready "$workspace"; then
      graph_query "$workspace" "$task" "$arch_max" > "$run_dir/architecture.txt" 2>/dev/null || true
    fi
  fi
  [ -s "$run_dir/architecture.txt" ] || echo "(none — not needed for this risk level, or no graph available)" > "$run_dir/architecture.txt"

  journal_run_transition "$run_dir" REVIEWING
  _orchestrate_review_loop "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$validation_json" "$require_strict_approval" "$changed_files"
}

# orchestrate_run <workspace> <task-text>
# Prints progress and the lead's final answer to stdout as it happens.
# Returns 0 when the loop reaches an approved/non-blocking end state, 1
# otherwise (reviewer unreachable/invalid twice, a blocking finding
# survives the max correction rounds, workspace conflict, or cancellation).
# Never turns a 1 into a 0.
orchestrate_run() {
  local workspace="$1" task="$2"
  local run_id base_head dirty_at_start
  run_id="$(run_id_generate)"
  base_head="$(git_safety_current_head "$workspace")"
  dirty_at_start="false"
  if project_is_git_repo "$workspace" 2>/dev/null && [ -n "$(project_git_status "$workspace" 2>/dev/null)" ]; then
    dirty_at_start="true"
  fi

  if ! workspace_lock_acquire "$workspace" "$run_id"; then
    echo "FINAL RESULT: error — another run is already active in this workspace." >&2
    return 1
  fi

  local run_dir
  run_dir="$(journal_run_create "$workspace" "$run_id" "$task" "$base_head" "$dirty_at_start")"
  git_safety_snapshot "$workspace" "$run_dir"
  journal_event_emit "$run_dir" "run.created"
  orchestrate_capture_project_profile "$workspace" "$run_dir"
  echo "run: $run_id"
  echo "run artifacts: $run_dir"

  # P2.4/P2.13: any SIGINT/SIGTERM to `agent` itself (Ctrl+C, a supervisor
  # stop, VPS shutdown) marks the run INTERRUPTED — recording which phase
  # was actually in flight — instead of leaving a journal frozen mid-write,
  # or silently losing the workspace lock. lib/git_safety.sh's
  # journal_call_in_flight is what later tells "safe to just retry this
  # phase" apart from "workspace may be mid-edit, uncertain" (P2.10).
  # NOTE: `trap ... RETURN` must be set directly in THIS function's body —
  # bash fires it on the return of whichever function last called `trap`,
  # not on the return of that function's caller, so factoring this out into
  # a helper would fire it (and release the lock) immediately instead.
  _orchestrate_on_interrupt() {
    local sig="$1" pre_state
    pre_state="$(journal_run_get_state "$run_dir" 2>/dev/null || echo "")"
    proc_cancel_request "$run_dir" >/dev/null 2>&1 || true
    if [ -n "$pre_state" ] && ! run_state_is_terminal "$pre_state" 2>/dev/null; then
      journal_run_update "$run_dir" "interrupted_from_state=$pre_state" >/dev/null 2>&1 || true
      if run_state_can_transition "$pre_state" INTERRUPTED; then
        journal_run_transition "$run_dir" INTERRUPTED >/dev/null 2>&1 || true
      fi
    fi
    workspace_lock_release "$workspace" "$run_id" >/dev/null 2>&1 || true
    echo >&2
    echo "FINAL RESULT: interrupted ($sig) — run $run_id marked INTERRUPTED. Resume with: agent resume $run_id" >&2
    exit 130
  }
  trap '_orchestrate_on_interrupt SIGINT' INT
  trap '_orchestrate_on_interrupt SIGTERM' TERM
  trap 'workspace_lock_release "$workspace" "$run_id" >/dev/null 2>&1 || true; trap - RETURN INT TERM' RETURN

  local max_rounds
  max_rounds="$(orchestrate_max_rounds)"

  journal_run_transition "$run_dir" CONTEXT
  printf '%s' "$task" > "$run_dir/task.txt"

  echo
  echo "== Step 0/6: gathering context (memory / graph / research) =="
  journal_event_emit "$run_dir" "context.started"
  context_build "$workspace" "$task" "$run_dir/context.md"
  if [ ! -s "$run_dir/context.md" ]; then
    echo "(no automatic context was gathered — investigate normally.)" > "$run_dir/context.md"
  fi
  local ctx_chars ctx_memory=false ctx_graph=false ctx_external=false
  ctx_chars=$(wc -c < "$run_dir/context.md" | tr -d ' ')
  grep -q '^## Memory' "$run_dir/context.md" && ctx_memory=true
  grep -q '^## Architecture' "$run_dir/context.md" && ctx_graph=true
  grep -q '^## External research' "$run_dir/context.md" && ctx_external=true
  journal_event_emit "$run_dir" "context.completed" "total_chars=$ctx_chars" "memory_used=$ctx_memory" "graph_used=$ctx_graph" "external_used=$ctx_external"

  journal_run_transition "$run_dir" IMPLEMENTING "last_completed_phase=CONTEXT_READY"

  echo
  echo "== Step 1/6: Claude Code implements =="
  orchestrate_render "$_ORCH_ROOT_DIR/harness/prompts/lead.md" \
    "TASK=$run_dir/task.txt" \
    "CONTEXT=$run_dir/context.md" \
    > "$run_dir/lead-message.txt"
  if ! orchestrate_call_dsh_tracked "$workspace" "$run_dir" lead "$run_dir/lead-message.txt" "$run_dir/lead-out.txt" claude lead; then
    if [ "$ORCHESTRATE_LAST_FAILURE_CATEGORY" = "CANCELLED" ]; then
      _orchestrate_finish "$run_dir" "$workspace" CANCELLED CANCELLED implementation "run cancelled during implementation"
      echo "FINAL RESULT: cancelled — run $run_id was cancelled during implementation." >&2
      return 1
    fi
    _orchestrate_finish "$run_dir" "$workspace" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" implementation "could not reach the lead (Claude Code) profile"
    echo "FINAL RESULT: error — could not reach the lead (Claude Code) profile." >&2
    return 1
  fi
  local lead_answer
  lead_answer="$(cat "$run_dir/lead-out.txt")"
  printf '%s\n' "$lead_answer"
  journal_run_update "$run_dir" "last_completed_phase=IMPLEMENTATION_DONE"

  if ! project_is_git_repo "$workspace"; then
    echo
    echo "FINAL RESULT: error — $workspace is not a git repository; cannot collect a diff to validate or review." >&2
    _orchestrate_finish "$run_dir" "$workspace" FAILED CONFIGURATION implementation "workspace is not a git repository"
    return 1
  fi

  local changed_files
  changed_files="$(project_git_changed_files "$workspace")"
  journal_run_transition "$run_dir" VALIDATING
  if [ -z "$changed_files" ]; then
    echo
    echo "FINAL RESULT: no files changed — nothing to validate or review."
    _orchestrate_finish "$run_dir" "$workspace" COMPLETED "" "" "no files changed"
    return 0
  fi

  _orchestrate_validate_and_review "$workspace" "$run_dir" "$run_id" "$task" "$max_rounds" "$changed_files" false
}
