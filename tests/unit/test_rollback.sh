#!/usr/bin/env bash
# P3.11 + P3.19: rollback, incl. "rollback also fails" and "irreversible
# migration -> rollback is only partial". No network, no LLM. Operates on a
# throwaway copy of the stack (AGENT_STACK_ROOT), never the live checkout.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
for m in policy environment version_drift compat capability_probe inventory state_paths \
         run_lifecycle journal update_discovery update_plan migration_detect snapshot \
         update_stage update_verify update_apply rollback; do
  source "$ROOT_DIR/lib/$m.sh"
done
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$HOME/.claude-mem" "$TMP/installed"

# throwaway "stack root"
export AGENT_STACK_ROOT="$TMP/stack"
mkdir -p "$AGENT_STACK_ROOT/policies"
cat > "$AGENT_STACK_ROOT/compat.yaml" <<'EOF'
schema_version: 1
acme-tool:
  tested: "1.0.0"
  source: "npm:@acme/tool"
  critical: false
  required_capabilities: []
  rollback: "npm i -g @acme/tool@<old>"
claude-mem:
  tested: "13.16.0"
  source: "npm:claude-mem"
  critical: false
  required_capabilities: []
EOF
echo "original policy content" > "$AGENT_STACK_ROOT/policies/thing.yaml"
echo "v: 1" > "$AGENT_STACK_ROOT/versions.yaml"
export AGENT_COMPAT_FILE="$AGENT_STACK_ROOT/compat.yaml"

cat > "$TMP/inv" <<EOF
#!/usr/bin/env bash
cat "$TMP/installed/\$1" 2>/dev/null
EOF
chmod +x "$TMP/inv"; export AGENT_INVENTORY_FIXTURE="$TMP/inv"
echo "1.0.0" > "$TMP/installed/acme-tool"

cat > "$TMP/reinstall" <<EOF
#!/usr/bin/env bash
[ "\${REINSTALL_FAIL:-0}" = "1" ] && exit 1
echo "\$2" > "$TMP/installed/\$1"
EOF
chmod +x "$TMP/reinstall"; export AGENT_ROLLBACK_INSTALL_FIXTURE="$TMP/reinstall"
export AGENT_VERIFY_REGRESSION_CMD="true"

cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "CLAUDE_MEM_PROVIDER": "openrouter", "CLAUDE_MEM_API_KEY": "sk-CURRENT-secret", "note": "original" }
EOF

# --- snapshot, then mutate everything ---
snap="$(snapshot_create "pre-update:acme-tool@2.0.0" 2>/dev/null)"
echo "2.0.0" > "$TMP/installed/acme-tool"
echo "TAMPERED" > "$AGENT_STACK_ROOT/policies/thing.yaml"
cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "CLAUDE_MEM_PROVIDER": "changed", "CLAUDE_MEM_API_KEY": "sk-NEW-secret", "note": "changed by update" }
EOF

out="$(rollback_run "$snap" 2>&1)"
assert_contains "$out" "ROLLBACK_COMPLETE" "a clean rollback reports ROLLBACK_COMPLETE"
assert_eq "1.0.0" "$(cat "$TMP/installed/acme-tool")" "rollback reinstalls the recorded version"
assert_eq "original policy content" "$(cat "$AGENT_STACK_ROOT/policies/thing.yaml")" "rollback restores stack config from the snapshot"
assert_contains "$(cat "$HOME/.claude-mem/settings.json")" "sk-NEW-secret" "rollback does NOT overwrite a file that currently holds a secret"
assert_contains "$out" "SKIP (holds a secret" "rollback reports the secret-bearing file it left in place"

# --- adversarial: a reinstall during rollback fails -> ROLLBACK_PARTIAL ---
echo "2.0.0" > "$TMP/installed/acme-tool"
export REINSTALL_FAIL=1
out="$(rollback_run "$snap" 2>&1)"
unset REINSTALL_FAIL
assert_contains "$out" "ROLLBACK_PARTIAL" "a failed reinstall during rollback is reported as PARTIAL, not complete"

# --- adversarial: irreversible forward migration -> rollback is PARTIAL ---
echo "13.16.0" > "$TMP/installed/claude-mem"
snap2="$(snapshot_create "pre-update:claude-mem@14.0.0" 2>/dev/null)"
echo "14.0.0" > "$TMP/installed/claude-mem"
out="$(rollback_run "$snap2" 2>&1)"
assert_contains "$out" "ROLLBACK_PARTIAL" "rolling back an irreversible claude-mem migration is PARTIAL"
assert_contains "$out" "NOT reversible" "the rollback is explicit that migrated data cannot be undone"

# --- unknown snapshot id ---
assert_exit_code "1" "rollback of an unknown snapshot id fails clearly" rollback_run snap-does-not-exist

# --- rollback verification failure keeps it PARTIAL ---
echo "2.0.0" > "$TMP/installed/acme-tool"
export AGENT_VERIFY_REGRESSION_CMD="false"
out="$(rollback_run "$snap" 2>&1)"
export AGENT_VERIFY_REGRESSION_CMD="true"
assert_contains "$out" "ROLLBACK_PARTIAL" "rollback is not 'complete' until its own verification passes"

report_and_exit
