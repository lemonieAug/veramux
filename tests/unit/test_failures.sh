#!/usr/bin/env bash
# P2.7: failure taxonomy classification.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/failures.sh"
set +e

# --- exit-code classification (deterministic, our own conventions) ---
assert_eq "TIMEOUT" "$(failure_classify_exit_code 124)" "exit 124 is TIMEOUT (our proc_timeout convention)"
assert_eq "CANCELLED" "$(failure_classify_exit_code 130)" "exit 130 is CANCELLED (SIGINT, matches dsh's own docs)"
assert_eq "TIMEOUT" "$(failure_classify_exit_code 137)" "exit 137 without a cancel marker is timeout escalation"
assert_eq "" "$(failure_classify_exit_code 1)" "an ordinary exit 1 has no special exit-code meaning"

# --- text heuristic (last resort, documented as such) ---
assert_eq "AUTHENTICATION" "$(failure_classify_text 'Error: Unauthorized (401)')" "detects authentication failure text"
assert_eq "QUOTA" "$(failure_classify_text 'insufficient_quota: you have exceeded your quota')" "detects quota text"
assert_eq "RATE_LIMIT" "$(failure_classify_text 'Error 429: Too Many Requests')" "detects rate limit text"
assert_eq "PROVIDER_UNAVAILABLE" "$(failure_classify_text 'connect ECONNREFUSED 127.0.0.1:443')" "detects provider-unavailable text"
assert_eq "" "$(failure_classify_text 'some ordinary error message' || true)" "unrecognized text classifies as nothing (not a guess)"

# --- failure_classify: hint wins, then exit code, then text, then INTERNAL ---
assert_eq "VALIDATION_FAILURE" "$(failure_classify 1 'npm test failed' VALIDATION_FAILURE)" "an explicit caller hint always wins"
assert_eq "TIMEOUT" "$(failure_classify 124 'anything' '')" "falls back to exit-code classification without a hint"
assert_eq "QUOTA" "$(failure_classify 1 'insufficient_quota' '')" "falls back to text heuristic when exit code is unclassified"
assert_eq "INTERNAL" "$(failure_classify 1 'totally unrecognized failure' '')" "falls back to INTERNAL when nothing else applies"
assert_eq "INTERNAL" "$(failure_classify 1 'x' 'NOT_A_REAL_CATEGORY')" "an invalid hint is ignored, not trusted blindly"

# --- retryability: the fixed, small list ---
assert_exit_code "0" "RATE_LIMIT is retryable" failure_is_retryable RATE_LIMIT
assert_exit_code "0" "PROVIDER_UNAVAILABLE is retryable" failure_is_retryable PROVIDER_UNAVAILABLE
assert_exit_code "0" "TIMEOUT is retryable before provider fallback" failure_is_retryable TIMEOUT
assert_exit_code "0" "MALFORMED_OUTPUT is retryable" failure_is_retryable MALFORMED_OUTPUT
assert_exit_code "1" "AUTHENTICATION is never retryable" failure_is_retryable AUTHENTICATION
assert_exit_code "1" "QUOTA is never retryable" failure_is_retryable QUOTA
assert_exit_code "1" "VALIDATION_FAILURE is never retryable" failure_is_retryable VALIDATION_FAILURE
assert_exit_code "1" "REVIEW_FAILURE (changes_requested) is never retryable" failure_is_retryable REVIEW_FAILURE
assert_exit_code "1" "CONFIGURATION is never retryable" failure_is_retryable CONFIGURATION
assert_exit_code "1" "WORKSPACE_CONFLICT is never retryable" failure_is_retryable WORKSPACE_CONFLICT
assert_exit_code "1" "GIT_CONFLICT is never retryable" failure_is_retryable GIT_CONFLICT

# --- failure_result_json shape ---
result="$(failure_result_json QUOTA review "Codex quota unavailable" run-123)"
assert_contains "$result" '"status":"failed"' "failure result has status=failed"
assert_contains "$result" '"category":"QUOTA"' "failure result carries the category"
assert_contains "$result" '"phase":"review"' "failure result carries the phase"
assert_contains "$result" '"retryable":false' "QUOTA failure result is marked non-retryable"
assert_contains "$result" '"run_id":"run-123"' "failure result carries the run_id"

result2="$(failure_result_json RATE_LIMIT lead "temporary provider hiccup" run-456)"
assert_contains "$result2" '"retryable":true' "RATE_LIMIT failure result is marked retryable, derived from the category — never passed independently"

report_and_exit
