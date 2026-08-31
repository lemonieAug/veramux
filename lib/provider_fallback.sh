#!/usr/bin/env bash
# Relay-provider selection and fail-closed fallback policy.
#
# This layer chooses only the small DSH driving model. It never configures or
# authenticates the Claude Code / Codex child processes. Every orchestration
# call starts at DeepSeek again; a successful OpenAI fallback is deliberately
# not sticky.
set -euo pipefail

_PROVIDER_FALLBACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROVIDER_FALLBACK_ROOT_DIR="$(cd "$_PROVIDER_FALLBACK_LIB_DIR/.." && pwd)"
_PROVIDER_FALLBACK_POLICY="$_PROVIDER_FALLBACK_ROOT_DIR/policies/runtime.yaml"

provider_primary() { printf 'deepseek\n'; }
provider_fallback() { printf 'openai\n'; }

# Logical provider names are kept stable in the Veramux journal. DSH's native
# DeepSeek adapter exposes the route as deepseek-official; llm-pi-ai exposes
# the configured OpenAI route as openai.
provider_dsh_route() {
  case "$1" in
    deepseek) printf 'deepseek-official\n' ;;
    openai) printf 'openai\n' ;;
    *) return 1 ;;
  esac
}

provider_is_configured() {
  local provider="$1" env_file="${2:-}"
  case "$provider" in
    deepseek) env_orchestrator_deepseek_configured "$env_file" ;;
    openai) env_orchestrator_openai_configured "$env_file" ;;
    *) return 1 ;;
  esac
}

# The allowlist is policy data, but the decision remains fail-closed: a missing
# policy value or an unknown category never enables fallback.
provider_fallback_categories() {
  policy_get "$_PROVIDER_FALLBACK_POLICY" provider_fallback eligible_categories ""
}

provider_fallback_is_eligible() {
  local category="$1" configured="${2:-true}" allowed candidate
  if [ "$configured" != "true" ]; then
    [ "$category" = "PROVIDER_UNAVAILABLE" ]
    return $?
  fi
  allowed="$(provider_fallback_categories)"
  [ -n "$allowed" ] || return 1
  while IFS= read -r candidate; do
    [ "$candidate" = "$category" ] && return 0
  done < <(printf '%s\n' "$allowed" | tr ',' '\n' | tr -d ' \t\r')
  return 1
}

provider_fallback_reason() {
  local category="$1" configured="${2:-true}"
  if [ "$configured" != "true" ] && [ "$category" = "PROVIDER_UNAVAILABLE" ]; then
    printf 'primary_not_configured\n'
    return 0
  fi
  case "$category" in
    RATE_LIMIT) printf 'rate_limit\n' ;;
    QUOTA) printf 'quota_exhausted\n' ;;
    TIMEOUT) printf 'timeout_after_retries\n' ;;
    PROVIDER_UNAVAILABLE) printf 'provider_unavailable\n' ;;
    *) return 1 ;;
  esac
}
