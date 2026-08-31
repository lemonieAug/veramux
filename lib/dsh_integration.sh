#!/usr/bin/env bash
# Hybrid DSH integration policy. This file deliberately owns only selection,
# capability and invocation boundaries; lib/orchestrate.sh remains the
# deterministic controller for validation, risk, journal, locking and resume.
set -euo pipefail

_DSH_INTEGRATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DSH_INTEGRATION_ROOT_DIR="$(cd "$_DSH_INTEGRATION_LIB_DIR/.." && pwd)"

dsh_engine_default() {
  if declare -F policy_get >/dev/null 2>&1; then
    policy_get "$_DSH_INTEGRATION_ROOT_DIR/policies/orchestration.yaml" orchestration engine legacy
  else
    printf 'legacy'
  fi
  printf '\n'
}
dsh_tool_mode_default() {
  if declare -F policy_get >/dev/null 2>&1; then
    policy_get "$_DSH_INTEGRATION_ROOT_DIR/policies/orchestration.yaml" orchestration tool_mode native
  else
    printf 'native'
  fi
  printf '\n'
}

# dsh_engine_requested <workspace> [cli-value]
# CLI has precedence over a project config, then the deliberately conservative
# legacy default. Values are validated by dsh_engine_resolve.
dsh_engine_requested() {
  local workspace="$1" cli_value="${2:-}" value
  if [ -n "$cli_value" ]; then printf '%s\n' "$cli_value"; return 0; fi
  value="$(project_config_orchestration_value "$workspace" engine "$(dsh_engine_default)")"
  printf '%s\n' "$value"
}

dsh_tool_mode_requested() {
  local workspace="$1" cli_value="${2:-}" value
  if [ -n "$cli_value" ]; then printf '%s\n' "$cli_value"; return 0; fi
  value="$(project_config_orchestration_value "$workspace" tool_mode "$(dsh_tool_mode_default)")"
  printf '%s\n' "$value"
}

dsh_engine_resolve() {
  case "$1" in
    legacy|dsh) printf '%s\n' "$1" ;;
    *) echo "error: invalid orchestration engine '$1' (valid: legacy, dsh)" >&2; return 1 ;;
  esac
}

# The upstream primitive is intentionally reported separately from the
# Veramux policy decision. Worker-thread containment is not an OS boundary.
dsh_programmatic_primitive() { printf 'code\n'; }
dsh_programmatic_block_reason() {
  printf '%s\n' "Programmatic orchestration is not allowed with the installed DSH CodeRuntime because it does not preserve Veramux's single-writer boundary."
}

# dsh_tool_mode_resolve <requested> -> native. A programmatic request is a
# hard policy error; it must never silently turn into native.
dsh_tool_mode_resolve() {
  case "$1" in
    native) printf 'native\n' ;;
    auto) printf 'native\n' ;;
    programmatic)
      dsh_programmatic_block_reason >&2
      return 1
      ;;
    *) echo "error: invalid tool mode '$1' (valid: native, auto, programmatic)" >&2; return 1 ;;
  esac
}

dsh_engine_support_status() {
  env_has_cmd dsh || { printf 'MISSING\n'; return 0; }
  if declare -F version_drift_installed_dsh >/dev/null 2>&1 && declare -F version_drift_pinned >/dev/null 2>&1 && declare -F version_drift_status >/dev/null 2>&1; then
    version_drift_status "$(version_drift_installed_dsh)" "$(version_drift_pinned dsh)"
  else
    printf 'UNKNOWN\n'
  fi
}

dsh_engine_available() {
  # Native mode relies on the pinned headless primitive. An unknown or drifted
  # runtime does not block legacy, but it is not silently accepted for the
  # explicit DSH engine.
  [ "$(dsh_engine_support_status)" = SUPPORTED ]
}

# dsh_integration_record <run-dir> <requested-engine> <resolved-engine>
#                        <requested-tool-mode> <resolved-tool-mode>
dsh_integration_record() {
  local run_dir="$1" requested_engine="$2" resolved_engine="$3"
  local requested_mode="$4" resolved_mode="$5"
  journal_run_update "$run_dir" \
    "engine_requested=$requested_engine" "engine_resolved=$resolved_engine" \
    "tool_mode_requested=$requested_mode" "tool_mode_resolved=$resolved_mode" \
    "programmatic_requested=false" "programmatic_allowed=false"
  journal_event_emit "$run_dir" "dsh.engine.selected" \
    "engine_requested=$requested_engine" "engine_resolved=$resolved_engine" \
    "tool_mode_requested=$requested_mode" "tool_mode_resolved=$resolved_mode"
}

dsh_integration_record_programmatic_block() {
  local run_dir="$1" requested_engine="$2" requested_mode="$3"
  journal_run_update "$run_dir" \
    "engine_requested=$requested_engine" "tool_mode_requested=$requested_mode" \
    "programmatic_requested=true" "programmatic_allowed=false" \
    "programmatic_block_reason=unsafe_same_process_runtime"
  journal_event_emit "$run_dir" "dsh.programmatic.blocked" \
    "engine_requested=$requested_engine" "tool_mode_requested=$requested_mode" \
    "reason=unsafe_same_process_runtime"
}

# dsh_integration_exec <workspace> <profile> <message> <provider>
# This is the single execution seam for the hybrid engine. Native is forced
# for BOTH engines so an ambient DSH_TOOLS_MODE can never enable Code Mode in
# the real workspace. Engine selection is recorded by the caller and does not
# grant a different execution authority to this child process.
dsh_integration_exec() {
  local workspace="$1" profile="$2" message="$3" provider="$4"
  ( cd "$workspace"
    export DSH_TOOLS_MODE=native
    export VERAMUX_RELAY_PROVIDER="$provider"
    case "$provider" in
      deepseek) unset VERAMUX_OPENAI_API_KEY ;;
      openai) unset VERAMUX_DEEPSEEK_API_KEY ;;
      *) exit 2 ;;
    esac
    exec dsh --profile "$profile" "$message"
  )
}
