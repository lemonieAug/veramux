#!/usr/bin/env bash
# P3.3: the compatibility manifest layer (lib/compat.sh over compat.yaml).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1

widget-core:
  tested: "2.4.1"
  source: "npm:@acme/widget-core"
  scope: "global"
  critical: true
  required_capabilities:
    - alpha-backend
    - beta-backend
  migration_notes: "breaking between minors"
  rollback: "reinstall pinned"

helper-tool:
  tested: "1.0.0"
  source: "system"
  scope: "system"
  critical: false
  required_capabilities: []
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"

# --- component enumeration ---
comps="$(compat_components)"
assert_contains "$comps" "widget-core" "compat_components lists a component section"
assert_contains "$comps" "helper-tool" "compat_components lists every component section"
assert_not_contains "$comps" "schema_version" "compat_components skips the schema_version scalar"
assert_exit_code "0" "compat_has_component finds a present component" compat_has_component widget-core
assert_exit_code "1" "compat_has_component rejects an unknown component" compat_has_component nope

# --- fields ---
assert_eq "2.4.1" "$(compat_tested_version widget-core)" "compat_tested_version reads the pin"
assert_eq "npm:@acme/widget-core" "$(compat_source widget-core)" "compat_source reads the source"
assert_exit_code "0" "compat_is_critical true for a critical component" compat_is_critical widget-core
assert_exit_code "1" "compat_is_critical false for a non-critical component" compat_is_critical helper-tool

caps="$(compat_required_capabilities widget-core)"
assert_contains "$caps" "alpha-backend" "compat_required_capabilities lists each capability"
assert_contains "$caps" "beta-backend" "compat_required_capabilities lists each capability"
assert_eq "" "$(compat_required_capabilities helper-tool)" "an empty capability list yields nothing"

# --- status vocabulary ---
assert_eq "MISSING" "$(compat_status widget-core "")" "no installed version is MISSING"
assert_eq "TESTED" "$(compat_status widget-core "2.4.1")" "exact match is TESTED"
assert_eq "SUPPORTED" "$(compat_status widget-core "2.4.5")" "same major.minor, newer patch is SUPPORTED"
assert_eq "NEWER_UNTESTED" "$(compat_status widget-core "2.5.0")" "newer minor is NEWER_UNTESTED"
assert_eq "NEWER_UNTESTED" "$(compat_status widget-core "3.0.0")" "newer major is NEWER_UNTESTED"
assert_eq "OLDER" "$(compat_status widget-core "2.3.9")" "an older version is OLDER"
assert_eq "NEWER_UNTESTED" "$(compat_status widget-core "not-a-version")" "an unparsable version is treated conservatively, never TESTED"

assert_exit_code "0" "TESTED counts as safe" compat_status_is_safe TESTED
assert_exit_code "0" "SUPPORTED counts as safe" compat_status_is_safe SUPPORTED
assert_exit_code "1" "NEWER_UNTESTED is not automatically safe" compat_status_is_safe NEWER_UNTESTED
assert_exit_code "1" "INCOMPATIBLE is not safe" compat_status_is_safe INCOMPATIBLE

# --- the real shipped manifest parses and covers the critical components ---
unset AGENT_COMPAT_FILE
real="$(compat_components)"
for must in deepseek-harness claude-code codex claude-mem graphify agent-reach node git; do
  assert_contains "$real" "$must" "shipped compat.yaml declares $must"
done
assert_exit_code "0" "shipped manifest marks deepseek-harness critical" compat_is_critical deepseek-harness
assert_contains "$(compat_required_capabilities deepseek-harness)" "codex-subagent" "shipped manifest keeps the codex-subagent capability requirement"

report_and_exit
