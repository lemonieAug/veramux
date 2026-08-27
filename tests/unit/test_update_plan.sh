#!/usr/bin/env bash
# P3.5: update planning (lib/update_plan.sh). Deterministic — no network
# (fixture registry), no LLM, no mutation.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
source "$ROOT_DIR/lib/capability_probe.sh"
source "$ROOT_DIR/lib/inventory.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/update_discovery.sh"
source "$ROOT_DIR/lib/update_plan.sh"
source "$ROOT_DIR/lib/migration_detect.sh"
set +e

# --- risk classification is deterministic and rule-based ---
assert_eq "major" "$(_plan_semver_bump 1.2.3 2.0.0)" "semver bump: major"
assert_eq "minor" "$(_plan_semver_bump 1.2.3 1.3.0)" "semver bump: minor"
assert_eq "patch" "$(_plan_semver_bump 1.2.3 1.2.4)" "semver bump: patch"
assert_eq "none"  "$(_plan_semver_bump 1.2.3 1.2.3)" "semver bump: none"
assert_eq "unknown" "$(_plan_semver_bump 1.2.3 not-a-version)" "semver bump: unparseable -> unknown"

assert_eq "HIGH" "$(update_risk deepseek-harness 0.1.1 0.1.2)" "any dsh update is HIGH regardless of bump size"
assert_eq "HIGH" "$(update_risk claude-code 0.1.1 0.1.2)" "any Claude bundle update is HIGH"
assert_eq "HIGH" "$(update_risk codex 0.1.1 0.1.2)" "any Codex bundle update is HIGH"
assert_eq "LOW" "$(update_risk claude-mem 13.16.0 13.16.1)" "a claude-mem patch is LOW"
assert_eq "MEDIUM" "$(update_risk claude-mem 13.16.0 13.17.0)" "a claude-mem minor is MEDIUM"
assert_eq "HIGH" "$(update_risk claude-mem 13.16.0 14.0.0)" "a claude-mem MAJOR is HIGH (possible irreversible storage migration)"
assert_eq "MEDIUM" "$(update_risk graphify 0.9.50 0.10.0)" "a Graphify minor is MEDIUM"
assert_eq "LOW" "$(update_risk graphify 0.9.50 0.9.51)" "a Graphify patch is LOW"
assert_eq "MEDIUM" "$(update_risk graphify 0.9.50 0.9.51 false)" "a patch that cannot be staged in isolation escalates LOW->MEDIUM"
assert_eq "HIGH" "$(update_risk somewidget 1.0.0 not-a-version)" "an unparseable candidate never stays LOW"

# --- a full plan for a controlled component ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1

git:
  tested: "2.49.0"
  source: "system"
  critical: true
  required_capabilities: []

acme-tool:
  tested: "1.0.0"
  source: "npm:@acme/tool"
  critical: false
  required_capabilities:
    - alpha
  migration_notes: "no known migrations"
  rollback: "npm i -g @acme/tool@<old>"
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"
export AGENT_UPDATE_REGISTRY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/fixture"
export AGENT_INVENTORY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/installed"
export FIXTURE__acme_tool="1.1.0"
export INSTALLED_acme_tool="1.0.0"

plan="$(update_plan_for acme-tool)"
assert_contains "$plan" "component: acme-tool" "plan names the component"
assert_contains "$plan" "candidate: 1.1.0" "plan shows the discovered candidate version"
assert_contains "$plan" "risk: MEDIUM" "plan classifies a non-critical minor as MEDIUM"
assert_contains "$plan" "apply_command: npm install -g @acme/tool@1.1.0" "plan shows the exact command apply would run"
assert_contains "$plan" "post_update_capability_checks:" "plan lists the capability probes that would gate the apply"
assert_contains "$plan" "  - alpha" "plan lists each required capability"
assert_contains "$plan" "rollback: npm i -g @acme/tool@<old>" "plan states the rollback strategy"

assert_exit_code "1" "planning an unknown component fails clearly" update_plan_for no-such-component

# --- JSON shape ---
pj="$(update_plan_for acme-tool | node "$ROOT_DIR/lib/json-tools.mjs" plan-build)"
assert_contains "$pj" '"component":"acme-tool"' "plan JSON carries the component"
assert_contains "$pj" '"risk":"MEDIUM"' "plan JSON carries the risk tier"
assert_contains "$pj" '"critical":false' "plan JSON coerces booleans"
assert_contains "$pj" '"post_update_capability_checks":["alpha"]' "plan JSON collects list items into an array"

# --- plan mutates nothing ---
before="$(git -C "$ROOT_DIR" status --porcelain; git -C "$ROOT_DIR" rev-parse HEAD; ls -a "$TMP" | sort)"
update_plan_for acme-tool >/dev/null
update_plan_print acme-tool >/dev/null
after="$(git -C "$ROOT_DIR" status --porcelain; git -C "$ROOT_DIR" rev-parse HEAD; ls -a "$TMP" | sort)"
assert_eq "$before" "$after" "update plan changes nothing on disk"

report_and_exit
