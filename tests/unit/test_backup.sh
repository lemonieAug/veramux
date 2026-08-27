#!/usr/bin/env bash
# P3.18: user backup / restore (lib/backup.sh). No LLM. Operates on a
# throwaway stack root and HOME.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
for m in policy environment version_drift compat capability_probe inventory state_paths \
         run_lifecycle journal update_discovery update_plan migration_detect snapshot \
         update_stage update_verify rollback backup; do
  source "$ROOT_DIR/lib/$m.sh"
done
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude-mem"
export AGENT_STACK_ROOT="$TMP/stack"; mkdir -p "$AGENT_STACK_ROOT/policies" "$AGENT_STACK_ROOT/scripts"
echo "schema_version: 1" > "$AGENT_STACK_ROOT/compat.yaml"
echo "orig policy" > "$AGENT_STACK_ROOT/policies/p.yaml"
echo "v: 1" > "$AGENT_STACK_ROOT/versions.yaml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AGENT_STACK_ROOT/scripts/doctor.sh"; chmod +x "$AGENT_STACK_ROOT/scripts/doctor.sh"
export AGENT_COMPAT_FILE="$AGENT_STACK_ROOT/compat.yaml"

cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "provider": "openrouter", "OPENROUTER_API_KEY": "sk-SECRET-do-not-back-up", "runtime": "worker" }
EOF

# --- create ---
arch="$(backup_create 2>/dev/null | tail -1)"
assert_eq "1" "$([ -f "$arch" ] && echo 1 || echo 0)" "backup_create writes an archive"
assert_contains "$arch" ".tar.gz" "the backup is a tarball"

# --- secrets are NOT in the archive ---
contents="$(tar xzf "$arch" -O 2>/dev/null)"
assert_not_contains "$contents" "sk-SECRET-do-not-back-up" "a claude-mem api key never lands in a backup"
assert_contains "$contents" "\"OPENROUTER_API_KEY\": null" "the key is nulled in the backed-up settings"
assert_contains "$contents" "orig policy" "stack policy files ARE backed up"

# --- restore into a mutated world ---
echo "TAMPERED" > "$AGENT_STACK_ROOT/policies/p.yaml"
cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "provider": "changed", "OPENROUTER_API_KEY": "sk-CURRENT-secret", "runtime": "worker" }
EOF
out="$(backup_restore "$arch" --yes 2>&1)"
assert_contains "$out" "RESTORE_OK" "a clean restore reports RESTORE_OK"
assert_eq "orig policy" "$(cat "$AGENT_STACK_ROOT/policies/p.yaml")" "restore brings back the stack config"
assert_contains "$(cat "$HOME/.claude-mem/settings.json")" "sk-CURRENT-secret" "restore does NOT overwrite the current machine's secret"

# --- refuse non-interactive without --yes ---
out="$(backup_restore "$arch" </dev/null 2>&1)"
assert_contains "$out" "refusing to restore non-interactively without --yes" "restore needs --yes non-interactively"

# --- corrupt archive ---
echo "not a tarball" > "$TMP/bad.tar.gz"
assert_exit_code "1" "restoring a corrupt archive fails cleanly" backup_restore "$TMP/bad.tar.gz" --yes

report_and_exit
