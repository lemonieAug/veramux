#!/usr/bin/env bash
# Project-level overrides (P1.12): optional $workspace/.agent/config.yaml.
# Precedence, documented in README: built-in defaults (policies/*.yaml) ->
# project config -> (no CLI/runtime override flag exists yet in P1). A
# missing file changes nothing — every function here falls back to the
# caller-supplied default. Sourced by bin/agent. Must not be executed
# directly.
set -euo pipefail

project_config_path() {
  printf '%s/.agent/config.yaml' "$1"
}

project_config_exists() {
  [ -f "$(project_config_path "$1")" ]
}

# project_config_bool <workspace> <section> <key> <default: true|false>
project_config_bool() {
  local workspace="$1" section="$2" key="$3" default="$4"
  local path
  path="$(project_config_path "$workspace")"
  if [ -f "$path" ]; then
    policy_get_bool "$path" "$section" "$key" "$default"
  else
    [ "$default" = "true" ]
  fi
}

# project_config_extra_high_risk_paths <workspace>
# Additive only (see lib/risk.sh: a project widens HIGH, never narrows it).
project_config_extra_high_risk_paths() {
  local workspace="$1" path
  path="$(project_config_path "$workspace")"
  [ -f "$path" ] && policy_get_nested_list "$path" review high_risk_paths
  return 0
}

project_config_always_review() {
  local workspace="$1" path
  path="$(project_config_path "$workspace")"
  [ -f "$path" ] && policy_get_bool "$path" review always_review false
}

# project_config_validation_command <workspace> <label: test|lint|typecheck|build>
# Prints the project's override command for that label, or empty.
project_config_validation_command() {
  local workspace="$1" label="$2" path
  path="$(project_config_path "$workspace")"
  [ -f "$path" ] || return 0
  policy_get "$path" validation "$label" ""
}

# project_config_orchestration_value <workspace> <key> <default>
# Kept in one place so engine/tool-mode precedence does not leak into the
# deterministic controller. Only the tiny scalar YAML shape policy_get
# supports is accepted.
project_config_orchestration_value() {
  local workspace="$1" key="$2" default="$3" path
  path="$(project_config_path "$workspace")"
  [ -f "$path" ] && policy_get "$path" orchestration "$key" "$default" || printf '%s' "$default"
}
