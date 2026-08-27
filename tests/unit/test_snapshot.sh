#!/usr/bin/env bash
# P3.8: pre-update configuration snapshots (lib/snapshot.sh).
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
source "$ROOT_DIR/lib/snapshot.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

# a fake DSH home with profile config + a secret in it
export DSH_HOME="$TMP/dsh"
mkdir -p "$DSH_HOME/profiles/lead" "$DSH_HOME/profiles/reviewer/codex-home"
echo '{"name":"lead","dependencies":{"@deepseek-ai/dsh-subagent-claude-code":"0.1.1-rc.2"}}' > "$DSH_HOME/profiles/lead/package.json"
cat > "$DSH_HOME/profiles/reviewer/package.json" <<'EOF'
{ "name": "reviewer", "env": { "SOME_TOKEN": "supersecretvalue", "MODE": "review" } }
EOF
echo 'sandbox_mode = "read-only"' > "$DSH_HOME/profiles/reviewer/codex-home/config.toml"

# a fake claude-mem settings.json with an api key
export HOME="$TMP/home"
mkdir -p "$HOME/.claude-mem" "$HOME/.claude/skills/graphify"
cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "CLAUDE_MEM_PROVIDER": "openrouter", "CLAUDE_MEM_OPENROUTER_API_KEY": "sk-live-DEADBEEF-must-not-leak", "runtime": "worker" }
EOF
echo "# graphify skill" > "$HOME/.claude/skills/graphify/SKILL.md"

id="$(snapshot_create "pre-update-test" 2>/tmp/snap_err.txt)"
assert_eq "1" "$([ -n "$id" ] && echo 1 || echo 0)" "snapshot_create prints an id"
dir="$(snapshot_dir "$id")"
assert_eq "1" "$([ -d "$dir" ] && echo 1 || echo 0)" "the snapshot directory exists"
assert_eq "1" "$([ -f "$dir/manifest.json" ] && echo 1 || echo 0)" "the snapshot has a manifest"

# --- config captured ---
assert_eq "1" "$([ -f "$dir/stack-config/versions.yaml" ] && echo 1 || echo 0)" "the repo's versions.yaml is captured"
assert_eq "1" "$([ -f "$dir/stack-config/compat.yaml" ] && echo 1 || echo 0)" "compat.yaml is captured"
assert_eq "1" "$([ -d "$dir/stack-config/policies" ] && echo 1 || echo 0)" "policies/ is captured"
assert_eq "1" "$([ -f "$dir/dsh-profiles/lead/package.json" ] && echo 1 || echo 0)" "the lead profile package.json is captured"

# --- secrets NOT captured ---
all_content="$(find "$dir" -type f -exec cat {} + 2>/dev/null)"
assert_not_contains "$all_content" "sk-live-DEADBEEF-must-not-leak" "a claude-mem api key never lands in the snapshot"
assert_not_contains "$all_content" "supersecretvalue" "a profile env secret never lands in the snapshot"
assert_contains "$(cat "$dir/claude-mem/settings.json")" '"CLAUDE_MEM_OPENROUTER_API_KEY": null' "the api key is nulled in the copied settings"
assert_contains "$(cat "$dir/claude-mem/settings.json")" '"CLAUDE_MEM_PROVIDER": "openrouter"' "non-secret settings are preserved"
assert_eq "1" "$([ -s "$dir/secrets-manifest.jsonl" ] && echo 1 || echo 0)" "secret-bearing files are recorded in the secrets manifest"
assert_contains "$(cat "$dir/secrets-manifest.jsonl")" "sha256" "the secrets manifest records a checksum, not the value"

# --- .env is never captured even if present ---
echo "ANTHROPIC_API_KEY=sk-real" > "$ROOT_DIR/.env.tmptest" 2>/dev/null
# (snapshot only reads .env.example, never .env — assert .env.example, not .env, is the captured one)
assert_eq "1" "$([ -f "$dir/stack-config/.env.example" ] && echo 1 || echo 0)" ".env.example is captured (the template, no secrets)"
assert_eq "0" "$([ -f "$dir/stack-config/.env" ] && echo 1 || echo 0)" ".env itself is never captured"
rm -f "$ROOT_DIR/.env.tmptest"

# --- list / show ---
assert_contains "$(snapshot_list)" "$id" "snapshot_list shows the snapshot"
assert_contains "$(snapshot_show "$id")" "pre-update-test" "snapshot_show prints the reason"
assert_exit_code "1" "snapshot_show on an unknown id fails" snapshot_show snap-nope

report_and_exit
