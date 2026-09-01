#!/usr/bin/env bash
# P3.2: deterministic component inventory (lib/inventory.sh).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
source "$ROOT_DIR/lib/inventory.sh"
set +e

# --- _inv_semver extraction ---
assert_eq "22.23.2" "$(_inv_semver "v22.23.2")" "strips a leading v"
assert_eq "0.12.5" "$(_inv_semver "uv 0.12.5 (210d1f678 2026-08-14)")" "picks the version out of a noisy line"
assert_eq "2.49.0" "$(_inv_semver "git version 2.49.0.windows.1")" "drops a platform tail like .windows.1"
assert_eq "0.1.1-rc.2" "$(_inv_semver "0.1.1-rc.2")" "keeps an -rc prerelease suffix"
assert_eq "" "$(_inv_semver "no digits here")" "prints nothing when there is no version"

# --- inventory against a controlled manifest ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1

git:
  tested: "2.49.0"
  source: "system"
  scope: "system"
  critical: true
  required_capabilities: []

deepseek-harness:
  tested: "0.1.1-rc.2"
  source: "npm:@deepseek-ai/dsh"
  scope: "global"
  critical: true
  required_capabilities:
    - claude-code-subagent
    - codex-subagent
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"
export AGENT_INVENTORY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/installed"
export INSTALLED_git="2.49.0"
unset INSTALLED_deepseek_harness

rows="$(inventory_collect)"
assert_eq "2" "$(printf '%s\n' "$rows" | grep -c .)" "one row per component"

git_row="$(printf '%s\n' "$rows" | grep '^git')"
git_installed="$(printf '%s' "$git_row" | cut -f2)"
git_status="$(printf '%s' "$git_row" | cut -f5)"
assert_eq "2.49.0" "$git_installed" "the fixture controls the reported system-tool version"
assert_eq "TESTED" "$git_status" "the fixture makes compatibility deterministic"

# Fixture deliberately reports no DSH -> MISSING, independent of the host.
dsh_row="$(printf '%s\n' "$rows" | grep '^deepseek-harness')"
assert_eq "-" "$(printf '%s' "$dsh_row" | cut -f2)" "a missing component's version field is the '-' placeholder (never a collapsed empty field)"
assert_eq "MISSING" "$(printf '%s' "$dsh_row" | cut -f5)" "a missing component is MISSING"
assert_eq "true" "$(printf '%s' "$dsh_row" | cut -f6)" "criticality is carried through"

# --- JSON assembly ---
json="$(inventory_collect | node "$ROOT_DIR/lib/json-tools.mjs" inventory-build)"
assert_contains "$json" '"schema_version":1' "inventory JSON carries a schema_version"
assert_contains "$json" '"name":"deepseek-harness"' "inventory JSON lists each component"
assert_contains "$json" '"installed_version":null' "a missing component serializes installed_version as null, not \"-\""
assert_contains "$json" '"capabilities":["claude-code-subagent","codex-subagent"]' "capabilities become a JSON array"
assert_contains "$json" '"critical":true' "critical is a boolean"

# --- inventory never mutates anything ---
before="$(find "$TMP" -type f | sort; git -C "$ROOT_DIR" rev-parse HEAD)"
inventory_collect >/dev/null
inventory_print >/dev/null
after="$(find "$TMP" -type f | sort; git -C "$ROOT_DIR" rev-parse HEAD)"
assert_eq "$before" "$after" "inventory is read-only — it creates/changes no files"

report_and_exit
