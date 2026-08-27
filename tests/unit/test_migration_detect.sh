#!/usr/bin/env bash
# P3.7: config / skill / data migration detection (lib/migration_detect.sh).
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

sev() { migration_detect "$1" "$2" "$3" | sed -n 's/^severity: //p'; }

assert_eq "irreversible" "$(sev claude-mem 13.16.0 14.0.0)" "a claude-mem MAJOR is an irreversible data migration"
assert_eq "reversible"   "$(sev claude-mem 13.16.0 13.16.1)" "a claude-mem patch is reversible"
assert_eq "reversible"   "$(sev graphify 0.9.50 0.10.0)" "a Graphify update is reversible (skill/config files)"
assert_eq "reversible"   "$(sev deepseek-harness 0.1.1 0.1.2)" "a dsh update is reversible (npm reinstall + configure)"
assert_eq "unknown"      "$(sev deepseek-harness 0.1.1 garbage)" "an unparseable candidate -> unknown severity"

assert_exit_code "0" "migration_is_irreversible true for a claude-mem major" migration_is_irreversible claude-mem 13.16.0 14.0.0
assert_exit_code "1" "migration_is_irreversible false for a claude-mem patch" migration_is_irreversible claude-mem 13.16.0 13.16.1

out="$(migration_detect claude-mem 13.16.0 14.0.0)"
assert_contains "$out" "NEVER delete" "claude-mem major surfaces the do-not-delete-storage warning"
assert_contains "$out" "rollback as PARTIAL" "claude-mem major is explicit that rollback is partial"

out2="$(migration_detect deepseek-harness 0.1.1 0.1.2)"
assert_contains "$out2" "re-run scripts/configure.sh" "a dsh update reminds to reconfigure"
assert_contains "$out2" "capability probe" "a dsh update reminds to re-probe capabilities"

out3="$(migration_detect graphify 0.9.50 0.10.0)"
assert_contains "$out3" "SKILL.md install location" "a Graphify update warns about the skill path drifting"

# plan integration: an irreversible migration forces HIGH + caps rollback_scope
export AGENT_UPDATE_REGISTRY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/fixture"
export AGENT_INVENTORY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/installed"
export INSTALLED_claude_mem="13.16.0"
export FIXTURE_claude_mem="14.0.0"
plan="$(update_plan_for claude-mem)"
assert_contains "$plan" "risk: HIGH" "an irreversible migration forces the plan risk to HIGH"
assert_contains "$plan" "migration_severity: irreversible" "the plan reports the migration severity"
assert_contains "$plan" "rollback_scope: partial" "the plan is honest that rollback would be partial"

report_and_exit
