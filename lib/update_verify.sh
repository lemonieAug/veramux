#!/usr/bin/env bash
# P3.10: post-update (and post-rollback) verification. After anything is
# installed or restored, prove the stack is actually in the state we
# expect — the installed version really changed, the required capability
# probes still pass, doctor is clean, and (for a real apply) the P0/P1/P2/P3
# deterministic suites still pass. Nothing here calls an LLM or spends
# provider quota; the optional live smoke test is a separate explicit step.
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_UPDATE_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UPDATE_VERIFY_ROOT_DIR="$(cd "$_UPDATE_VERIFY_LIB_DIR/.." && pwd)"

# update_verify_component <component> [expected_version]
# Fast checks scoped to one component. Prints a report; last line is a token:
#   verify_ok | verify_version_mismatch | verify_capability_failed | verify_unknown
update_verify_component() {
  local component="$1" expected="${2:-}"
  local installed; installed="$(inventory_detect_version "$component")"
  echo "verify[$component]: installed version now = ${installed:-<none>}"

  if [ -n "$expected" ] && [ -n "$installed" ]; then
    local want got
    want="$(printf '%s' "$expected"  | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    got="$(printf '%s'  "$installed" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    if [ -n "$want" ] && [ -n "$got" ] && [ "$want" != "$got" ]; then
      echo "verify[$component]: MISMATCH — expected $expected, found $installed"
      echo "verify_version_mismatch"; return 0
    fi
  fi

  local verdict; verdict="$(capability_verdict "$component")"
  echo "verify[$component]: capability verdict = $verdict"
  case "$verdict" in
    INCOMPATIBLE)
      capability_probe_component "$component" | sed 's/^/  /'
      echo "verify_capability_failed"; return 0 ;;
    UNVERIFIED)
      echo "verify[$component]: (some capabilities need a live run — see benchmark --live)"
      echo "verify_unknown"; return 0 ;;
    *)
      echo "verify_ok"; return 0 ;;
  esac
}

update_verify_result() { printf '%s' "$1" | tail -1; }

# update_verify_regression
# doctor + the full deterministic unit suite. Seam: AGENT_VERIFY_REGRESSION_CMD
# lets a test substitute a fast stub. Prints a token on the last line:
#   regression_ok | regression_failed
update_verify_regression() {
  if [ -n "${AGENT_VERIFY_REGRESSION_CMD:-}" ]; then
    if $AGENT_VERIFY_REGRESSION_CMD; then echo "regression_ok"; else echo "regression_failed"; fi
    return 0
  fi
  local ok=1
  echo "verify: running agent doctor ..."
  bash "$_UPDATE_VERIFY_ROOT_DIR/scripts/doctor.sh" >/dev/null 2>&1 || ok=0
  echo "verify: running the deterministic unit suite (P0/P1/P2/P3) ..."
  bash "$_UPDATE_VERIFY_ROOT_DIR/tests/unit/run.sh" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then echo "regression_ok"; else echo "regression_failed"; fi
}
