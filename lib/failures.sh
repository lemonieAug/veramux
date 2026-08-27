#!/usr/bin/env bash
# P2.7: failure taxonomy. No LLM classifies a failure — exit codes and our
# own known signals decide first; a small curated text-pattern table is the
# documented last resort for the provider-side categories DSH's one-shot
# text-in/text-out contract doesn't expose a structured diagnostic for (see
# docs/upstream-findings.md P2 section). Sourced by bin/agent. Must not be
# executed directly.
set -euo pipefail

FAILURE_CATEGORIES="CONFIGURATION AUTHENTICATION QUOTA RATE_LIMIT PROVIDER_UNAVAILABLE TIMEOUT CANCELLED TOOL_FAILURE VALIDATION_FAILURE REVIEW_FAILURE MALFORMED_OUTPUT WORKSPACE_CONFLICT GIT_CONFLICT INTERNAL"

failure_category_is_valid() {
  local c="$1" candidate
  for candidate in $FAILURE_CATEGORIES; do
    [ "$candidate" = "$c" ] && return 0
  done
  return 1
}

# failure_classify_exit_code <exit_code>
# Deterministic mapping for signals WE control (our own timeout/cancel
# wrapper — see lib/proc_timeout.sh, which uses these exact conventions).
# Prints empty (not a guess) for an ordinary nonzero exit with no special
# meaning — the caller has better information than a bare exit code there.
failure_classify_exit_code() {
  case "$1" in
    124) printf 'TIMEOUT\n' ;;
    130) printf 'CANCELLED\n' ;;
    137) printf 'CANCELLED\n' ;;
    *) printf '\n' ;;
  esac
}

# failure_classify_text <combined stdout+stderr text>
# LAST-RESORT heuristic (spec: "somente use pattern matching textual quando
# não houver interface melhor") for the provider-side categories DSH does
# not expose a structured diagnostic for to an external caller. Prints
# empty when nothing matches — callers must not treat that as INTERNAL by
# default, only as "unclassified by this heuristic".
failure_classify_text() {
  local text
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *"rate limit"*|*"429"*|*"too many requests"*)
      printf 'RATE_LIMIT\n'; return 0 ;;
  esac
  case "$text" in
    *"quota"*|*"insufficient_quota"*|*"usage limit"*|*"billing hard limit"*)
      printf 'QUOTA\n'; return 0 ;;
  esac
  case "$text" in
    *"unauthorized"*|*"not logged in"*|*"authentication failed"*|*"invalid api key"*|*"invalid_api_key"*|*"401"*|*"please log in"*)
      printf 'AUTHENTICATION\n'; return 0 ;;
  esac
  case "$text" in
    *"econnrefused"*|*"enotfound"*|*"getaddrinfo"*|*"503"*|*"service unavailable"*|*"could not connect"*)
      printf 'PROVIDER_UNAVAILABLE\n'; return 0 ;;
  esac
  printf '\n'
  return 1
}

# failure_classify <exit_code> <text> [hint]
# The one function orchestration code should call. Precedence: an explicit
# hint from a caller that already KNOWS the category deterministically
# (e.g. "VALIDATION_FAILURE" after validation_run returns nonzero,
# "WORKSPACE_CONFLICT" from lib/workspace_lock.sh, "GIT_CONFLICT" from a
# resume-time git-state mismatch) always wins; then our own exit-code
# conventions; then the text heuristic; INTERNAL only when nothing else
# applies.
failure_classify() {
  local exit_code="$1" text="$2" hint="${3:-}"
  if [ -n "$hint" ] && failure_category_is_valid "$hint"; then
    printf '%s\n' "$hint"
    return 0
  fi
  local by_code
  by_code="$(failure_classify_exit_code "$exit_code")"
  if [ -n "$by_code" ]; then
    printf '%s\n' "$by_code"
    return 0
  fi
  local by_text
  by_text="$(failure_classify_text "$text" || true)"
  if [ -n "$by_text" ]; then
    printf '%s\n' "$by_text"
    return 0
  fi
  printf 'INTERNAL\n'
}

# failure_is_retryable <category>
# P2.9's authoritative list of what may ever be retried automatically.
# Everything else — auth, quota, validation/review outcomes, config,
# workspace/git conflicts — must never be retried silently.
failure_is_retryable() {
  case "$1" in
    RATE_LIMIT|PROVIDER_UNAVAILABLE|MALFORMED_OUTPUT) return 0 ;;
    *) return 1 ;;
  esac
}

# failure_result_json <category> <phase> <message> <run_id>
# The P2.7 failure-result shape. retryable is derived from the category,
# never passed separately (so it can never drift from failure_is_retryable's
# own list).
failure_result_json() {
  local category="$1" phase="$2" message="$3" run_id="$4" retryable="false"
  failure_is_retryable "$category" && retryable="true"
  node "$(dirname "${BASH_SOURCE[0]}")/json-tools.mjs" build-object \
    "status=failed" "category=$category" "phase=$phase" \
    "retryable=$retryable" "message=$message" "run_id=$run_id"
}
