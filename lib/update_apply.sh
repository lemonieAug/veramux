#!/usr/bin/env bash
# P3.9: controlled apply. The ONLY path that changes an installed component,
# and it always: shows the plan -> snapshots config -> stages the candidate
# in isolation -> installs the EXPLICIT candidate version (never `latest`) ->
# verifies the component -> verifies no P0/P1/P2/P3 regression. A critical
# component that fails verification STOPS the run (the chain is not
# continued blindly) and the result names the snapshot to roll back to. No
# LLM. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_UPDATE_APPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UPDATE_APPLY_ROOT_DIR="$(cd "$_UPDATE_APPLY_LIB_DIR/.." && pwd)"

# _apply_install <component> <candidate>
# Runs the real install command from the plan. Seam:
# AGENT_APPLY_INSTALL_FIXTURE (script taking "<component> <candidate>") keeps
# unit tests off the network. Returns the installer's exit code.
_apply_install() {
  local component="$1" candidate="$2"
  if [ -n "${AGENT_APPLY_INSTALL_FIXTURE:-}" ]; then
    "$AGENT_APPLY_INSTALL_FIXTURE" "$component" "$candidate"
    return $?
  fi
  local cmd; cmd="$(update_plan_command "$component" "$candidate")"
  echo "apply: running: $cmd"
  bash -c "$cmd"
}

# update_apply_run <component> [--to <version>] [--yes] [--no-regression]
update_apply_run() {
  local component="" to="" assume_yes=0 run_regression=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="$2"; shift 2 ;;
      --yes|-y) assume_yes=1; shift ;;
      --no-regression) run_regression=0; shift ;;
      -*) echo "unknown flag: $1" >&2; return 2 ;;
      *) component="$1"; shift ;;
    esac
  done
  [ -n "$component" ] || { echo "usage: agent update apply <component> [--to <version>] [--yes]" >&2; return 2; }
  compat_has_component "$component" || { echo "error: unknown component: $component" >&2; return 2; }

  local scheme; scheme="$(_update_source_scheme "$(compat_source "$component")")"
  if [ "$scheme" = "system" ]; then
    echo "error: $component is a system component — upgrade it with the OS package manager, not 'agent update'." >&2
    return 2
  fi

  local candidate="$to"
  [ -n "$candidate" ] || candidate="$(update_available_version "$component")"
  if [ -z "$candidate" ]; then
    echo "error: no candidate version (registry unreachable and no --to given)." >&2
    return 1
  fi
  local current; current="$(inventory_detect_version "$component")"

  echo "=============================================================="
  update_plan_for "$component" | sed 's/^/  /' || true
  echo "=============================================================="

  if [ "$assume_yes" -ne 1 ]; then
    if [ -t 0 ]; then
      printf 'apply this update (%s: %s -> %s)? [y/N] ' "$component" "${current:-none}" "$candidate"
      local reply; read -r reply
      case "$reply" in y|Y|yes) ;; *) echo "aborted — nothing changed."; return 1 ;; esac
    else
      echo "refusing to apply non-interactively without --yes (nothing changed)." >&2
      return 1
    fi
  fi

  # 1. snapshot BEFORE anything changes
  local snap_id
  snap_id="$(snapshot_create "pre-update:$component@$candidate")" || { echo "error: snapshot failed — refusing to apply." >&2; return 1; }
  echo "apply: snapshot $snap_id taken."

  # 2. stage the candidate in isolation
  local stage_out stage_tok
  stage_out="$(stage_candidate "$component" "$candidate")"
  stage_tok="$(stage_result "$stage_out")"
  printf '%s\n' "$stage_out" | sed 's/^/  /'
  case "$stage_tok" in
    staged_failed)
      echo "APPLY ABORTED: the candidate failed isolated staging. Nothing was changed. (snapshot $snap_id is available but unused)" >&2
      return 1 ;;
    staging_not_available)
      echo "apply: NOTE — this candidate could not be verified in isolation; proceeding because --yes was given and a snapshot exists." ;;
    staged_ok)
      echo "apply: candidate verified in isolation." ;;
  esac

  # 3. install the EXPLICIT candidate
  if ! _apply_install "$component" "$candidate"; then
    echo "APPLY FAILED during install. Config snapshot $snap_id is intact." >&2
    echo "UPDATE_FAILED_ROLLBACK_AVAILABLE:$snap_id"
    return 1
  fi

  # 4. component verification
  local cv_out cv_tok
  cv_out="$(update_verify_component "$component" "$candidate")"
  printf '%s\n' "$cv_out" | sed 's/^/  /'
  cv_tok="$(update_verify_result "$cv_out")"
  if [ "$cv_tok" = "verify_version_mismatch" ] || [ "$cv_tok" = "verify_capability_failed" ]; then
    echo "APPLY FAILED verification for $component ($cv_tok)." >&2
    if migration_is_irreversible "$component" "$current" "$candidate"; then
      echo "UPDATE_FAILED_ROLLBACK_PARTIAL:$snap_id"
    else
      echo "UPDATE_FAILED_ROLLBACK_AVAILABLE:$snap_id"
    fi
    echo "  to roll back: agent update rollback $snap_id" >&2
    return 1
  fi

  # 5. regression gate (doctor + P0/P1/P2/P3 deterministic suites)
  if [ "$run_regression" -eq 1 ]; then
    local rg_out rg_tok
    rg_out="$(update_verify_regression)"
    printf '%s\n' "$rg_out" | sed 's/^/  /'
    rg_tok="$(update_verify_result "$rg_out")"
    if [ "$rg_tok" = "regression_failed" ]; then
      echo "APPLY FAILED: a P0/P1/P2/P3 regression appeared after updating $component." >&2
      if migration_is_irreversible "$component" "$current" "$candidate"; then
        echo "UPDATE_FAILED_ROLLBACK_PARTIAL:$snap_id"
      else
        echo "UPDATE_FAILED_ROLLBACK_AVAILABLE:$snap_id"
      fi
      echo "  to roll back: agent update rollback $snap_id" >&2
      return 1
    fi
  fi

  echo "UPDATE_SUCCESS: $component $current -> $candidate (snapshot $snap_id kept for rollback)"
  echo "next: consider a manual 'agent benchmark --live' before trusting it for real work."
  return 0
}
