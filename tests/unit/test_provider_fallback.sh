#!/usr/bin/env bash
# DeepSeek-primary / OpenAI-fallback policy, journal and key-isolation tests.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/journal.sh"
source "$ROOT_DIR/lib/failures.sh"
source "$ROOT_DIR/lib/proc_timeout.sh"
source "$ROOT_DIR/lib/retry.sh"
source "$ROOT_DIR/lib/provider_fallback.sh"
source "$ROOT_DIR/lib/orchestrate.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"
export PATH="$TESTS_DIR/fixtures/mock-dsh:$PATH"
export MOCK_DSH_MODE=happy
export MOCK_DSH_PROVIDER_LOG="$TMP/provider.log"
export VERAMUX_DEEPSEEK_API_KEY="deepseek-canary-never-log"
export VERAMUX_OPENAI_API_KEY="openai-canary-never-log"

# Keep deterministic retry tests fast without changing production policy.
retry_backoff_seconds() { echo 0; }

new_call() {
  local name="$1"
  local ws="$TMP/$name" run_id="run-$name" run_dir
  mkdir -p "$ws"
  run_dir="$(journal_run_create "$ws" "$run_id" "task" "head" "false")"
  journal_run_transition "$run_dir" CONTEXT >/dev/null
  journal_run_transition "$run_dir" IMPLEMENTING >/dev/null
  printf 'delegate this task' > "$run_dir/message.txt"
  printf '%s\n' "$run_dir"
}

call_provider() {
  local run_dir="$1"
  orchestrate_call_dsh_tracked "$(journal_run_get_field "$run_dir" workspace)" \
    "$run_dir" lead "$run_dir/message.txt" "$run_dir/out.txt" claude lead
}

count_provider() { grep -c $'\t'"$1"$'\t' "$MOCK_DSH_PROVIDER_LOG" 2>/dev/null || true; }

# 1. Healthy primary: no fallback call.
: > "$MOCK_DSH_PROVIDER_LOG"
export MOCK_PROVIDER_SCENARIO=primary_success
run1="$(new_call primary)"
call_provider "$run1"; code=$?
assert_eq "0" "$code" "healthy DeepSeek succeeds"
assert_eq "1" "$(count_provider deepseek)" "DeepSeek is called once"
assert_eq "0" "$(count_provider openai)" "OpenAI is not called when DeepSeek succeeds"
assert_contains "$(cat "$run1/out.txt")" "from deepseek" "primary response is preserved"

# 2-4. Eligible categories: retries first where permitted, then OpenAI.
for spec in "rate_limit:RATE_LIMIT:rate_limit" "quota:QUOTA:quota_exhausted" "timeout:TIMEOUT:timeout_after_retries"; do
  scenario="${spec%%:*}"; rest="${spec#*:}"; category="${rest%%:*}"; reason="${rest#*:}"
  : > "$MOCK_DSH_PROVIDER_LOG"
  export MOCK_PROVIDER_SCENARIO="$scenario"
  run="$(new_call "$scenario")"
  call_provider "$run"; code=$?
  assert_eq "0" "$code" "$category falls back successfully"
  assert_eq "1" "$(count_provider openai)" "$category calls OpenAI"
  assert_contains "$(cat "$run/events.jsonl")" '"fallback_triggered":true' "$category records fallback"
  assert_contains "$(cat "$run/events.jsonl")" "\"fallback_reason\":\"$reason\"" "$category records the reason"
  assert_eq "openai" "$(journal_run_get_field "$run" last_relay_provider)" "$category records OpenAI as responder"
done

# 5. Missing DeepSeek key with OpenAI present uses the documented degraded path.
: > "$MOCK_DSH_PROVIDER_LOG"
unset VERAMUX_DEEPSEEK_API_KEY
export MOCK_PROVIDER_SCENARIO=primary_success
run5="$(new_call missing-primary)"
call_provider "$run5"; code=$?
assert_eq "0" "$code" "missing DeepSeek key can use configured OpenAI"
assert_eq "0" "$(count_provider deepseek)" "unconfigured DeepSeek endpoint is not called"
assert_eq "1" "$(count_provider openai)" "OpenAI handles the degraded call"
assert_contains "$(cat "$run5/events.jsonl")" '"fallback_reason":"primary_not_configured"' "missing primary reason is explicit"
export VERAMUX_DEEPSEEK_API_KEY="deepseek-canary-never-log"

# 6. Unknown/local configuration failures are fail-closed.
: > "$MOCK_DSH_PROVIDER_LOG"
export MOCK_PROVIDER_SCENARIO=config_error
run6="$(new_call config-error)"
call_provider "$run6"; code=$?
assert_eq "1" "$code" "local/config error fails"
assert_eq "0" "$(count_provider openai)" "local/config error never falls back"
assert_contains "$(cat "$run6/events.jsonl")" '"reason":"not_eligible"' "fail-closed decision is journaled"

# 7-8. Both providers fail: final result and journal preserve both categories,
# while neither API key value appears in persisted artifacts.
: > "$MOCK_DSH_PROVIDER_LOG"
export MOCK_PROVIDER_SCENARIO=quota
export MOCK_OPENAI_FAILURE=auth
run7="$(new_call both-fail)"
call_provider "$run7"; code=$?
assert_eq "1" "$code" "both providers failing returns failure"
_orchestrate_finish "$run7" "$(journal_run_get_field "$run7" workspace)" FAILED "$ORCHESTRATE_LAST_FAILURE_CATEGORY" implementation "both relay providers failed"
final7="$(cat "$run7/final.json")"
assert_contains "$final7" '"primary_error":"QUOTA"' "final result preserves DeepSeek error"
assert_contains "$final7" '"fallback_error":"AUTHENTICATION"' "final result preserves OpenAI error"
persisted7="$(cat "$run7/run.json" "$run7/events.jsonl" "$run7/final.json")"
assert_not_contains "$persisted7" "deepseek-canary-never-log" "DeepSeek key is absent from journal/result"
assert_not_contains "$persisted7" "openai-canary-never-log" "OpenAI key is absent from journal/result"
unset MOCK_OPENAI_FAILURE

# 9. Fallback is not sticky: the next call starts at DeepSeek again.
: > "$MOCK_DSH_PROVIDER_LOG"
export MOCK_PROVIDER_SCENARIO=quota
run9="$(new_call non-sticky)"
call_provider "$run9" >/dev/null
export MOCK_PROVIDER_SCENARIO=primary_success
call_provider "$run9" >/dev/null
last_provider="$(tail -1 "$MOCK_DSH_PROVIDER_LOG" | cut -f2)"
assert_eq "deepseek" "$last_provider" "next call starts at DeepSeek after a fallback"

# 10. The unselected ambient key is removed before each DSH process. The mock
# exits 91/92 if isolation regresses; booleans in its log make this explicit.
assert_not_contains "$(cat "$MOCK_DSH_PROVIDER_LOG")" $'deepseek\tdeepseek_key=present\topenai_key=present' "OpenAI key is hidden from DeepSeek process"
export MOCK_PROVIDER_SCENARIO=quota
call_provider "$run9" >/dev/null
assert_contains "$(cat "$MOCK_DSH_PROVIDER_LOG")" $'openai\tdeepseek_key=absent\topenai_key=present' "OpenAI process sees only its relay key"

# Pure policy boundary: known local/unknown errors are never eligible.
for category in CONFIGURATION AUTHENTICATION INTERNAL MALFORMED_OUTPUT VALIDATION_FAILURE REVIEW_FAILURE CANCELLED; do
  if provider_fallback_is_eligible "$category" true; then
    FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $category must not be fallback-eligible" >&2
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
done

report_and_exit
