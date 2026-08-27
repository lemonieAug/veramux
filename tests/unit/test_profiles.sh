#!/usr/bin/env bash
# P3.14: optimization profiles (lib/profiles.sh) + their effect on review
# depth and context budget. No LLM.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/project_config.sh"
source "$ROOT_DIR/lib/profiles.sh"
source "$ROOT_DIR/lib/risk.sh"
set +e

# --- resolution ---
unset AGENT_PROFILE
assert_eq "balanced" "$(profile_active)" "default profile is balanced"
export AGENT_PROFILE="economy"
assert_eq "economy" "$(profile_active)" "AGENT_PROFILE selects the profile"
export AGENT_PROFILE="nonsense"
assert_eq "balanced" "$(profile_active)" "an invalid AGENT_PROFILE falls back to balanced"
unset AGENT_PROFILE
assert_exit_code "0" "economy is a valid profile" profile_is_valid economy
assert_exit_code "1" "garbage is not a valid profile" profile_is_valid garbage

# --- budgets ---
export AGENT_PROFILE="economy"
assert_eq "2000" "$(profile_budget memory_max_chars 4000)" "economy shrinks the memory budget"
assert_eq "18000" "$(profile_budget source_initial_max_chars 30000)" "economy shrinks the source budget"
assert_exit_code "1" "economy turns automatic web research off" profile_external_enabled

export AGENT_PROFILE="strict"
assert_eq "12000" "$(profile_budget graph_max_chars 8000)" "strict grows the graph budget"
assert_exit_code "0" "strict keeps web research on" profile_external_enabled

export AGENT_PROFILE="balanced"
assert_eq "4000" "$(profile_budget memory_max_chars 4000)" "balanced leaves the P1 budget untouched"

# --- the safety invariant: no profile weakens a HIGH-risk review ---
for p in economy balanced strict; do
  export AGENT_PROFILE="$p"
  assert_exit_code "0" "$p: HIGH risk still requires Codex" risk_requires_codex high
  assert_exit_code "0" "$p: HIGH risk still requires verification" risk_requires_verification high
done

# --- economy does NOT force MEDIUM Codex beyond policy; strict DOES ---
export AGENT_PROFILE="economy"
# policies/risk.yaml default has medium.codex=true, so this stays true anyway;
# the point is economy never returns "always" for medium (it defers to policy).
assert_eq "policy" "$(profile_review_codex medium)" "economy defers MEDIUM review to policy"
assert_eq "always" "$(profile_review_codex high)" "economy still forces HIGH review"
export AGENT_PROFILE="strict"
assert_eq "always" "$(profile_review_codex medium)" "strict always reviews MEDIUM"
assert_exit_code "0" "strict forces MEDIUM verification" risk_requires_verification medium

# --- balanced medium verification matches the P1 policy (false) ---
export AGENT_PROFILE="balanced"
assert_exit_code "1" "balanced does not add MEDIUM verification" risk_requires_verification medium

# --- project .agent/config.yaml can set the default profile ---
unset AGENT_PROFILE
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj/.agent"
echo "profile: strict" > "$TMP/proj/.agent/config.yaml"
assert_eq "strict" "$(profile_active "$TMP/proj")" "a project config profile: key is honored"
export AGENT_PROFILE="economy"
assert_eq "economy" "$(profile_active "$TMP/proj")" "an explicit --profile still overrides the project default"

report_and_exit
