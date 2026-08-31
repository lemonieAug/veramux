#!/usr/bin/env bash
# Environment / tool-presence / billing-risk helpers.
# Sourced by bin/agent and scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

env_has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

env_dsh_home() {
  if [ -n "${DSH_HOME:-}" ] && [ -n "$(printf '%s' "$DSH_HOME" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$DSH_HOME"
  else
    printf '%s\n' "$HOME/.dsh"
  fi
}

env_node_version() {
  if env_has_cmd node; then
    node --version 2>/dev/null | sed 's/^v//'
  fi
}

env_node_version_ok() {
  local ver major
  ver="$(env_node_version || true)"
  [ -n "$ver" ] || return 1
  major="${ver%%.*}"
  [ "$major" -ge 22 ] 2>/dev/null
}

env_pnpm_ok() {
  env_has_cmd pnpm
}

env_dsh_ok() {
  env_has_cmd dsh
}

# Presence-only lookup for a named variable in a DSH .env file. This parser
# never sources the file (which would execute shell code), and never prints a
# value. DSH's credential service performs the real per-request resolution.
env_file_var_configured() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 1
  awk -v wanted="$name" '
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq-1)
      value=substr(line, eq+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (key == wanted && value != "" && value !~ /^#/) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# Read a non-secret configuration value from a DSH .env file without sourcing
# it.  The first non-empty occurrence wins, matching the intended .env
# precedence while keeping shell syntax (including command substitutions) inert.
env_file_var_value() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 1
  awk -v wanted="$name" '
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq-1)
      value=substr(line, eq+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (key != wanted || value == "") next
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047")) {
        value=substr(value, 2, length(value)-2)
      }
      if (value == "") next
      print value
      found=1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

env_orchestrator_deepseek_configured() {
  local env_file="${1:-}"
  [ -n "${VERAMUX_DEEPSEEK_API_KEY:-}" ] || { [ -n "$env_file" ] && env_file_var_configured "$env_file" VERAMUX_DEEPSEEK_API_KEY; }
}

# This optional fallback key belongs only to DSH's relay model. It
# intentionally differs from OPENAI_API_KEY, which a host Codex CLI may
# interpret as an API-billing override. Profiles never forward it to Codex.
env_orchestrator_openai_configured() {
  local env_file="${1:-}"
  [ -n "${VERAMUX_OPENAI_API_KEY:-}" ] || { [ -n "$env_file" ] && env_file_var_configured "$env_file" VERAMUX_OPENAI_API_KEY; }
}

env_orchestrator_deepseek_model() {
  local env_file="${1:-}" value
  if [ -n "${VERAMUX_DEEPSEEK_MODEL:-}" ]; then
    printf '%s\n' "$VERAMUX_DEEPSEEK_MODEL"
  elif [ -n "$env_file" ] && value="$(env_file_var_value "$env_file" VERAMUX_DEEPSEEK_MODEL)"; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "deepseek-chat"
  fi
}

env_orchestrator_openai_model() {
  local env_file="${1:-}" value
  if [ -n "${VERAMUX_OPENAI_MODEL:-}" ]; then
    printf '%s\n' "$VERAMUX_OPENAI_MODEL"
  elif [ -n "$env_file" ] && value="$(env_file_var_value "$env_file" VERAMUX_OPENAI_MODEL)"; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "gpt-5-mini"
  fi
}

# Presence-only check for the two products' subagent runtimes inside a
# given DSH profile directory. Returns 0 if the bundle is listed.
env_profile_has_bundle() {
  local profile_pkg="$1" bundle_name="$2"
  [ -f "$profile_pkg" ] || return 1
  grep -q "\"$bundle_name\"" "$profile_pkg" 2>/dev/null
}

# Prints WARNING lines (never values) for credential-shaped env vars that are
# known billing-override footguns. Does not modify or unset anything.
# See docs/upstream-findings.md: DSH's Claude/Codex subagent providers scrub
# these from the child process unless our profile config forwards them
# explicitly, so this is a hygiene warning, not proof of active risk.
env_report_billing_risk_vars() {
  local found=0
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "WARNING: ANTHROPIC_API_KEY is set in this shell's environment."
    echo "  This does not by itself make our Claude Code subagent use API billing"
    echo "  (DeepSeek Harness scrubs it before the child process starts unless our"
    echo "  profile config explicitly forwards it — see docs/upstream-findings.md)."
    echo "  It can still affect a host 'claude' CLI run outside this stack."
    found=1
  fi
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: OPENAI_API_KEY is set in this shell's environment."
    echo "  Some Codex CLI versions prefer OPENAI_API_KEY over an authenticated"
    echo "  ChatGPT subscription login, which can cause silent pay-per-token"
    echo "  billing. This is scrubbed before reaching our reviewer's child"
    echo "  process by default, but a host 'codex' run outside this stack, or"
    echo "  a future profile edit, could still pick it up."
    found=1
  fi
  return "$found"
}

# Hard-fail check: our own profile config must never hardcode a credential
# into a subagent provider's `env:` block. This is the actual control point
# for unintended billing (see docs/upstream-findings.md).
env_scan_profiles_for_hardcoded_keys() {
  local profiles_dir="$1"
  local hit=0
  local f
  while IFS= read -r -d '' f; do
    # Dedicated relay references such as VERAMUX_OPENAI_API_KEY are allowed;
    # only the generic child-billing variable names as standalone identifiers
    # are forbidden here.
    if grep -qE '(^|[^A-Z0-9_])(ANTHROPIC_API_KEY|OPENAI_API_KEY)([^A-Z0-9_]|$)' "$f" 2>/dev/null; then
      echo "ERROR: $f explicitly references ANTHROPIC_API_KEY or OPENAI_API_KEY."
      echo "  A subagent provider's 'env:' block only receives credentials we put"
      echo "  there ourselves; DeepSeek Harness does not forward ambient keys."
      echo "  If this is intentional (you want API billing instead of the"
      echo "  authenticated subscription session), remove this warning source by"
      echo "  acknowledging it explicitly in policies/safety.yaml."
      hit=1
    fi
  done < <(find "$profiles_dir" -name 'cordis.patch.yml' -print0 2>/dev/null)
  return "$hit"
}

env_safety_allows_key_override() {
  local safety_file="$1"
  [ -f "$safety_file" ] || return 1
  grep -q '^allow_explicit_api_key_billing:[[:space:]]*true' "$safety_file" 2>/dev/null
}
