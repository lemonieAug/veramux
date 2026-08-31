#!/usr/bin/env bash
# Phase 1 hybrid engine behavior. All calls use the mock DSH, so this proves
# policy ordering and native-mode wiring without provider credentials.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
use_mock_dsh happy
export MOCK_DSH_CALL_LOG="$TMP/dsh-calls.log"

make_node_fixture "$TMP/default"
: > "$MOCK_DSH_CALL_LOG"
out="$(run_agent "$TMP/default" "Add validation to prevent negative numbers." 2>&1)"
code=$?
assert_eq "0" "$code" "legacy remains the default engine"
assert_contains "$(cat "$MOCK_DSH_CALL_LOG")" $'tools_mode=native' "legacy workflow forces native mode instead of inheriting Code Mode"
run_dir="$(find "$AGENT_STATE_HOME/runs" -path '*default*' -name run.json -printf '%h\n' | sort | tail -1)"
assert_eq "legacy" "$(node "$ROOT_DIR/lib/json-tools.mjs" get-field engine_resolved < "$run_dir/run.json")" "default engine resolution is journaled as legacy"

make_node_fixture "$TMP/config-dsh"
mkdir -p "$TMP/config-dsh/.agent"
cat > "$TMP/config-dsh/.agent/config.yaml" <<'EOF'
orchestration:
  engine: dsh
  tool_mode: auto
EOF
git -C "$TMP/config-dsh" add .agent/config.yaml && git -C "$TMP/config-dsh" -c user.email=test@example.com -c user.name=test commit -qm config
: > "$MOCK_DSH_CALL_LOG"
out="$(run_agent "$TMP/config-dsh" "Add validation to prevent negative numbers." 2>&1)"
code=$?
assert_eq "0" "$code" "project config selects the DSH engine"
assert_contains "$(cat "$MOCK_DSH_CALL_LOG")" $'tools_mode=native' "auto resolves to native before DSH invocation"
run_dir="$(find "$AGENT_STATE_HOME/runs" -path '*config-dsh*' -name run.json -printf '%h\n' | sort | tail -1)"
assert_eq "dsh" "$(node "$ROOT_DIR/lib/json-tools.mjs" get-field engine_resolved < "$run_dir/run.json")" "journal records resolved DSH engine"
assert_eq "native" "$(node "$ROOT_DIR/lib/json-tools.mjs" get-field tool_mode_resolved < "$run_dir/run.json")" "journal records conservative auto resolution"

make_node_fixture "$TMP/cli-wins"
mkdir -p "$TMP/cli-wins/.agent"
cat > "$TMP/cli-wins/.agent/config.yaml" <<'EOF'
orchestration:
  engine: dsh
  tool_mode: native
EOF
git -C "$TMP/cli-wins" add .agent/config.yaml && git -C "$TMP/cli-wins" -c user.email=test@example.com -c user.name=test commit -qm config
out="$(run_agent --engine legacy "$TMP/cli-wins" "Add validation to prevent negative numbers." 2>&1)"
code=$?
assert_eq "0" "$code" "CLI engine overrides project config"
run_dir="$(find "$AGENT_STATE_HOME/runs" -path '*cli-wins*' -name run.json -printf '%h\n' | sort | tail -1)"
assert_eq "legacy" "$(node "$ROOT_DIR/lib/json-tools.mjs" get-field engine_resolved < "$run_dir/run.json")" "CLI precedence is persisted"

make_node_fixture "$TMP/programmatic"
: > "$MOCK_DSH_CALL_LOG"
out="$(run_agent --engine dsh --programmatic "$TMP/programmatic" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "programmatic mode is a blocking policy error"
assert_contains "$out" "Programmatic orchestration is not allowed" "programmatic failure explains the single-writer boundary"
assert_eq "" "$(cat "$MOCK_DSH_CALL_LOG")" "programmatic is blocked before any DSH/provider/subagent call"

make_node_fixture "$TMP/config-programmatic"
mkdir -p "$TMP/config-programmatic/.agent"
cat > "$TMP/config-programmatic/.agent/config.yaml" <<'EOF'
orchestration:
  engine: dsh
  tool_mode: programmatic
EOF
git -C "$TMP/config-programmatic" add .agent/config.yaml && git -C "$TMP/config-programmatic" -c user.email=test@example.com -c user.name=test commit -qm config
: > "$MOCK_DSH_CALL_LOG"
out="$(run_agent "$TMP/config-programmatic" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "programmatic project config is a deterministic blocking error"
assert_eq "" "$(cat "$MOCK_DSH_CALL_LOG")" "blocked project config cannot reach DSH"

make_node_fixture "$TMP/invalid"
out="$(run_agent --engine unknown "$TMP/invalid" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "invalid engine fails deterministically"
assert_contains "$out" "invalid orchestration engine" "invalid engine explains accepted values"

make_node_fixture "$TMP/unsupported"
export MOCK_DSH_VERSION="9.9.9"
out="$(run_agent --engine dsh "$TMP/unsupported" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "unsupported DSH blocks only the opt-in DSH engine"
assert_contains "$out" "DSH-native engine unavailable" "unsupported DSH reports a deterministic capability error"
unset MOCK_DSH_VERSION

report_and_exit
