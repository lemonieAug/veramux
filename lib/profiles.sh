#!/usr/bin/env bash
# P3.14: optimization profiles (economy / balanced / strict). A thin layer
# over policies/profiles.yaml that lib/context.sh and lib/risk.sh consult
# through `command -v` guards — so nothing changes for callers that don't
# source this file (the P1 suites), and a real `agent` run picks up the
# selected profile. Never changes models; never lets a profile weaken a
# HIGH-risk review. No LLM. Sourced by bin/agent. Must not be executed
# directly.
set -euo pipefail

_PROFILES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROFILES_FILE="$(cd "$_PROFILES_LIB_DIR/.." && pwd)/policies/profiles.yaml"

PROFILE_NAMES="economy balanced strict"

profile_is_valid() {
  case " $PROFILE_NAMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# profile_active [workspace]
# AGENT_PROFILE env (from `agent --profile`) wins; then a project
# .agent/config.yaml `profile:` key; then `balanced`.
profile_active() {
  local workspace="${1:-}"
  if [ -n "${AGENT_PROFILE:-}" ] && profile_is_valid "$AGENT_PROFILE"; then
    printf '%s' "$AGENT_PROFILE"; return 0
  fi
  if [ -n "$workspace" ] && command -v project_config_path >/dev/null 2>&1; then
    local cfg p
    cfg="$(project_config_path "$workspace")"
    if [ -f "$cfg" ]; then
      p="$(policy_get_toplevel "$cfg" profile "")"
      profile_is_valid "$p" && { printf '%s' "$p"; return 0; }
    fi
  fi
  printf 'balanced'
}

# profile_setting <key> [workspace] -> raw value from profiles.yaml, or empty
profile_setting() {
  policy_get "$_PROFILES_FILE" "$(profile_active "${2:-}")" "$1" ""
}

# profile_budget <key> <base_value> [workspace]
# A numeric context budget: the profile's override, or the P1 base.
profile_budget() {
  local v; v="$(profile_setting "$1" "${3:-}")"
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$v" ;;
  esac
}

# profile_external_enabled [workspace] -> 0 (yes) / 1 (no)
# Only ever RESTRICTS: if the profile says external_enabled:false, research
# is off; otherwise the P1 policy decides.
profile_external_enabled() {
  [ "$(profile_setting external_enabled "${1:-}")" = "false" ] && return 1
  return 0
}

# profile_review_codex <tier> [workspace] -> always | policy | default
#   always   this tier is always sent to Codex under this profile
#   policy   only when policies/risk.yaml (or a project override) requires it
#   default  defer entirely to the P1 policy
# HIGH can never be anything but "always".
profile_review_codex() {
  local tier="$1" v
  [ "$tier" = "high" ] && { printf 'always'; return 0; }
  v="$(profile_setting "review_${tier}_codex" "${2:-}")"
  case "$v" in
    true)   printf 'always' ;;
    false)  printf 'default' ;;   # 'false' just means "no stronger than default"
    policy) printf 'policy' ;;
    *)      printf 'default' ;;
  esac
}

# profile_review_verification <tier> [workspace] -> 0 (force an extra pass) / 1 (defer)
profile_review_verification() {
  [ "$(profile_setting "review_$1_verification" "${2:-}")" = "true" ] && return 0
  return 1
}

profile_describe() {
  local p; p="$(profile_active "${1:-}")"
  echo "active profile: $p"
  case "$p" in
    economy) echo "  economy — smaller context budgets, no automatic web research, MEDIUM review only when policy requires it. HIGH-risk review and all safety enforcement are unchanged." ;;
    strict)  echo "  strict — larger context budgets, MEDIUM always reviewed + verified, HIGH verified. For changes you want maximum scrutiny on." ;;
    *)       echo "  balanced — the P1 calibration (progressive disclosure, risk-based review, standard budgets)." ;;
  esac
}
