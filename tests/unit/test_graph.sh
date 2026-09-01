#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/graph.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Without graphify on PATH: every function degrades to "unavailable",
# never an error.
hide_test_commands graphify
mkdir -p "$TMP/nograph"
graph_available
assert_eq "1" "$?" "graphify not on PATH -> unavailable"
graph_query "$TMP/nograph" "anything" 100
assert_eq "1" "$?" "query falls back cleanly when graphify is absent"

# With the mock graphify installed
show_test_commands
use_mock_graphify
mkdir -p "$TMP/withgraph"

graph_available
assert_eq "0" "$?" "graphify on PATH -> available"

graph_is_ready "$TMP/withgraph"
assert_eq "1" "$?" "not ready before ensure_ready runs"

graph_ensure_ready "$TMP/withgraph" >/dev/null 2>&1
assert_eq "1" "$([ -f "$TMP/withgraph/.claude/skills/graphify/SKILL.md" ] && echo 1 || echo 0)" "ensure_ready registers the project skill"
assert_eq "1" "$([ -f "$TMP/withgraph/graphify-out/graph.json" ] && echo 1 || echo 0)" "ensure_ready builds an initial graph"

graph_is_ready "$TMP/withgraph"
assert_eq "0" "$?" "ready after ensure_ready runs"

# Idempotent: a second call should not error and should leave things as-is
graph_ensure_ready "$TMP/withgraph" >/dev/null 2>&1
assert_eq "0" "$?" "ensure_ready is idempotent"

result="$(graph_query "$TMP/withgraph" "what connects auth to db?" 200)"
assert_contains "$result" "MOCK QUERY RESULT" "query returns the mock backend's answer"

truncated="$(graph_query "$TMP/withgraph" "some question" 5)"
assert_eq "5" "${#truncated}" "query output is truncated to max_chars"

report_and_exit
