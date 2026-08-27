#!/usr/bin/env bash
# P2.9: retry policy numbers, backoff arithmetic, and the retryable gate.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/failures.sh"
source "$ROOT_DIR/lib/retry.sh"
set +e

# --- policy numbers, read from policies/runtime.yaml ---
assert_eq "2" "$(retry_max_attempts transient)" "transient max_attempts from policy"
assert_eq "1" "$(retry_max_attempts malformed_review)" "malformed_review max_attempts from policy"
assert_eq "1" "$(retry_max_attempts unknown_kind)" "an unknown kind defaults to no retry (1 attempt)"

# --- backoff: exponential, capped ---
assert_eq "2" "$(retry_backoff_seconds 1)" "backoff attempt 1"
assert_eq "4" "$(retry_backoff_seconds 2)" "backoff attempt 2"
assert_eq "8" "$(retry_backoff_seconds 3)" "backoff attempt 3"
assert_eq "30" "$(retry_backoff_seconds 10)" "backoff is capped at 30s, never stalls a run for minutes"

# --- retry_should_retry: gates on both retryability AND attempt budget ---
assert_exit_code "0" "RATE_LIMIT with 1 attempt so far, budget 2: should retry" retry_should_retry RATE_LIMIT 1 transient
assert_exit_code "1" "RATE_LIMIT with 2 attempts so far, budget 2: exhausted" retry_should_retry RATE_LIMIT 2 transient
assert_exit_code "1" "AUTHENTICATION is never retried regardless of attempts_so_far" retry_should_retry AUTHENTICATION 0 transient
assert_exit_code "0" "MALFORMED_OUTPUT with 0 attempts so far, budget 1: should retry once" retry_should_retry MALFORMED_OUTPUT 0 malformed_review
assert_exit_code "1" "MALFORMED_OUTPUT with 1 attempt so far, budget 1: exhausted (only one retry allowed)" retry_should_retry MALFORMED_OUTPUT 1 malformed_review

report_and_exit
