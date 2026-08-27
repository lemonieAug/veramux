#!/usr/bin/env bash
# P2.4: run identity and the run state machine. Deliberately small — 11
# states total, matching the spec's own example exactly, not "dozens of
# states". Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

# run_id_generate
# "<UTC timestamp>-<6 hex chars>" — timestamp alone risks collision (two
# runs starting the same second), so every id carries a random suffix.
# Prefers /dev/urandom (real entropy); falls back to bash's $RANDOM, which
# is still fine for local single-machine uniqueness at this granularity.
run_id_generate() {
  local ts rand=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  if [ -z "$rand" ]; then
    rand="$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
  fi
  printf '%s-%s\n' "$ts" "${rand:0:6}"
}

# The complete state set (P2.4). Anything not in this list is invalid.
RUN_STATES="CREATED CONTEXT IMPLEMENTING VALIDATING REVIEWING CORRECTING VERIFYING COMPLETED FAILED CANCELLED INTERRUPTED"

run_state_is_valid() {
  local s="$1" candidate
  for candidate in $RUN_STATES; do
    [ "$candidate" = "$s" ] && return 0
  done
  return 1
}

run_state_is_terminal() {
  case "$1" in
    COMPLETED|FAILED|CANCELLED) return 0 ;;
    *) return 1 ;;
  esac
}

# run_state_can_transition <from> <to>
# The state machine's only source of truth. COMPLETED is reachable only
# from a point in the flow where the workflow's own conditions (validation
# passed, review approved or skipped per policy) are what the CALLER has
# already checked — this function only enforces STRUCTURAL validity, never
# invents business logic of its own.
run_state_can_transition() {
  local from="$1" to="$2"
  run_state_is_valid "$from" || return 1
  run_state_is_valid "$to" || return 1
  run_state_is_terminal "$from" && return 1
  # A state "transitioning" to itself is always a valid no-op — P2.10's
  # resume logic re-enters shared phase functions that end by (re)asserting
  # a state (e.g. REVIEWING) the run may already be in when resuming right
  # at that phase; requiring every caller to special-case that instead of
  # letting X->X be idempotent would be its own source of bugs.
  [ "$from" = "$to" ] && return 0

  case "$from" in
    CREATED)
      case "$to" in CONTEXT|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    CONTEXT)
      case "$to" in IMPLEMENTING|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    IMPLEMENTING)
      case "$to" in VALIDATING|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    VALIDATING)
      case "$to" in REVIEWING|COMPLETED|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    REVIEWING)
      case "$to" in CORRECTING|VERIFYING|COMPLETED|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    CORRECTING)
      case "$to" in VALIDATING|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    VERIFYING)
      case "$to" in COMPLETED|CORRECTING|FAILED|CANCELLED|INTERRUPTED) return 0 ;; esac ;;
    INTERRUPTED)
      # Resume (P2.10) re-enters at whichever phase the journal proves safe.
      case "$to" in CONTEXT|IMPLEMENTING|VALIDATING|REVIEWING|CORRECTING|VERIFYING|FAILED|CANCELLED) return 0 ;; esac ;;
  esac
  return 1
}
