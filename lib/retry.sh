#!/usr/bin/env bash
# P2.9: retry policy numbers + backoff arithmetic. Pure policy + math and
# testable in isolation — the actual retry LOOP lives in lib/orchestrate.sh,
# which already owns the call context (this mirrors how lib/risk.sh holds
# policy/classification while lib/orchestrate.sh owns the review loop).
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_RETRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RETRY_ROOT_DIR="$(cd "$_RETRY_LIB_DIR/.." && pwd)"
_RETRY_POLICY="$_RETRY_ROOT_DIR/policies/runtime.yaml"

# retry_max_attempts <kind: transient|malformed_review>
# Total attempts allowed, INCLUDING the first (1 = no retry).
retry_max_attempts() {
  case "$1" in
    transient) policy_get "$_RETRY_POLICY" retry transient_max_attempts 2 ;;
    malformed_review) policy_get "$_RETRY_POLICY" retry malformed_review_max_attempts 1 ;;
    *) echo 1 ;;
  esac
}

# retry_backoff_seconds <attempt: 1-based retry number>
# Exponential (2, 4, 8, ...), capped at 30s — a flaky call's own retry math
# should never stall a run for minutes.
retry_backoff_seconds() {
  local attempt="${1:-1}" seconds
  seconds=$(( 2 ** attempt ))
  [ "$seconds" -gt 30 ] && seconds=30
  echo "$seconds"
}

# retry_should_retry <category> <attempts_so_far> <kind>
# True only when the category is in lib/failures.sh's fixed retryable set
# AND this kind's attempt budget isn't exhausted yet. Authentication,
# quota, validation/review outcomes, configuration, and workspace/git
# conflicts are never retryable — failure_is_retryable is the single
# source of truth for that list, never re-decided here.
retry_should_retry() {
  local category="$1" attempts_so_far="$2" kind="$3" max
  failure_is_retryable "$category" || return 1
  max="$(retry_max_attempts "$kind")"
  [ "$attempts_so_far" -lt "$max" ]
}
