#!/usr/bin/env bash
# Deterministic risk classification and adaptive review depth (P1.9/P1.10).
# No LLM call decides risk — path/diff-content pattern matching only.
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_RISK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RISK_ROOT_DIR="$(cd "$_RISK_LIB_DIR/.." && pwd)"
_RISK_POLICY="$_RISK_ROOT_DIR/policies/risk.yaml"

_risk_path_matches_any() {
  local path="$1"; shift
  local base pattern
  base="$(basename "$path")"
  for pattern in "$@"; do
    [ -z "$pattern" ] && continue
    if [[ "$path" == $pattern ]] || [[ "$base" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# risk_classify <workspace> [extra_high_risk_path ...]
# Prints exactly one of: low | medium | high. Extra high-risk path patterns
# (from a project's .agent/config.yaml, P1.12) are additive — a project can
# widen HIGH, never narrow it below the built-in list.
risk_classify() {
  local workspace="$1"; shift
  local -a extra_high_paths=("$@")
  local -a high_paths low_paths high_keywords
  mapfile -t high_paths < <(policy_get_list "$_RISK_POLICY" high_risk_paths)
  mapfile -t low_paths < <(policy_get_list "$_RISK_POLICY" low_risk_paths)
  mapfile -t high_keywords < <(policy_get_list "$_RISK_POLICY" high_risk_diff_keywords)
  high_paths+=("${extra_high_paths[@]}")

  local -a changed_files
  mapfile -t changed_files < <(project_git_changed_files "$workspace")

  if [ "${#changed_files[@]}" -eq 0 ]; then
    printf 'low\n'
    return 0
  fi

  local f
  for f in "${changed_files[@]}"; do
    [ -z "$f" ] && continue
    if _risk_path_matches_any "$f" "${high_paths[@]}"; then
      printf 'high\n'
      return 0
    fi
  done

  local diff_text keyword
  diff_text="$(project_git_diff "$workspace")"
  for keyword in "${high_keywords[@]}"; do
    [ -z "$keyword" ] && continue
    if printf '%s' "$diff_text" | grep -qF -- "$keyword"; then
      printf 'high\n'
      return 0
    fi
  done

  local all_low=1
  for f in "${changed_files[@]}"; do
    [ -z "$f" ] && continue
    if ! _risk_path_matches_any "$f" "${low_paths[@]}"; then
      all_low=0
      break
    fi
  done
  if [ "$all_low" -eq 1 ]; then
    printf 'low\n'
    return 0
  fi

  printf 'medium\n'
}

# risk_review_setting <tier: low|medium|high> <key: codex|verification>
# Prints "true" or "false". Reads the fixed review.<tier>.<key> shape in
# policies/risk.yaml (three levels deep, so lib/policy.sh's two-level
# section/key reader doesn't cover it — small enough not to generalize).
risk_review_setting() {
  local tier="$1" key="$2"
  awk -v tier="$tier" -v key="$key" '
    /^review:/ { inreview=1; next }
    inreview && /^[a-zA-Z]/ { exit }
    inreview && $0 ~ ("^  " tier ":") { intier=1; next }
    inreview && intier && /^  [a-z]/ { intier=0 }
    inreview && intier && $0 ~ ("^    " key ":") {
      sub("^    " key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$_RISK_POLICY" 2>/dev/null
}

risk_requires_codex() {
  [ "$(risk_review_setting "$1" codex)" = "true" ]
}

risk_requires_verification() {
  [ "$(risk_review_setting "$1" verification)" = "true" ]
}
