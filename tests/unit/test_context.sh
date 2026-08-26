#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/project_config.sh"
source "$ROOT_DIR/lib/graph.sh"
source "$ROOT_DIR/lib/memory.sh"
source "$ROOT_DIR/lib/research.sh"
source "$ROOT_DIR/lib/context.sh"
set +e

TMP="$(mktemp -d)"
cleanup() { stop_mock_memory_server; rm -rf "$TMP"; }
trap cleanup EXIT

# No graphify, no memory, task doesn't need research -> grep fallback only.
make_node_fixture "$TMP/plain"
context_build "$TMP/plain" "Add validation to prevent negative numbers in the add function" "$TMP/out1.md"
out1="$(cat "$TMP/out1.md")"
assert_contains "$out1" "Possibly relevant source" "falls back to a grep-based section when no graph exists"
assert_contains "$out1" "add.js" "grep fallback finds the file the task is actually about"
assert_not_contains "$out1" "Architecture (knowledge graph)" "no graph section when graphify is unavailable"
assert_not_contains "$out1" "Memory (past work" "no memory section when the worker is unavailable"

# With graphify available: graph section appears, and grep fallback is
# skipped for the same need (mutual-exclusivity is this module's answer to
# duplication control — see lib/context.sh).
use_mock_graphify
make_node_fixture "$TMP/withgraph"
context_build "$TMP/withgraph" "Add validation to prevent negative numbers" "$TMP/out2.md"
out2="$(cat "$TMP/out2.md")"
assert_contains "$out2" "Architecture (knowledge graph)" "graph section appears once graphify is available"
assert_not_contains "$out2" "Possibly relevant source" "grep fallback is skipped once the graph answered (no duplication)"

# Project override disables graph/memory/research even when available.
mkdir -p "$TMP/withgraph/.agent"
cat > "$TMP/withgraph/.agent/config.yaml" <<'EOF'
graph:
  enabled: false
memory:
  enabled: false
research:
  enabled: false
EOF
context_build "$TMP/withgraph" "Add validation to prevent negative numbers" "$TMP/out3.md"
out3="$(cat "$TMP/out3.md")"
assert_not_contains "$out3" "Architecture (knowledge graph)" "project override disables the graph section"
# grep fallback fires again once graph is turned off for this project
assert_contains "$out3" "Possibly relevant source" "grep fallback returns once graph is disabled by override"

# Memory section, end to end, when the worker is up.
if start_mock_memory_server 37798; then
  make_node_fixture "$TMP/withmem"
  context_build "$TMP/withmem" "Investigate why the rate limiter breaks under concurrent load in production" "$TMP/out4.md"
  out4="$(cat "$TMP/out4.md")"
  assert_contains "$out4" "Memory (past work" "memory section appears once the worker is up and the query is long enough"
else
  echo "SKIP: could not start mock memory server for the memory-section assertion"
fi

report_and_exit
