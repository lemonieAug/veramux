#!/usr/bin/env bash
# Graphify integration (P1.2). Graphify is a real CLI (`graphify`, from the
# `graphifyy` PyPI package) that can be queried directly from bash — see
# docs/upstream-findings.md. This is an optimization, never a hard
# dependency: every function here degrades to "unavailable" instead of
# failing the run when graphify isn't installed, the skill isn't
# registered yet, or a query errors out.
set -euo pipefail

_GRAPH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GRAPH_ROOT_DIR="$(cd "$_GRAPH_LIB_DIR/.." && pwd)"
_GRAPH_POLICY="$_GRAPH_ROOT_DIR/policies/context.yaml"

graph_available() {
  env_has_cmd graphify
}

graph_json_path() {
  printf '%s/graphify-out/graph.json' "$1"
}

graph_run() {
  if env_has_cmd timeout; then
    timeout 60 graphify "$@"
  else
    graphify "$@"
  fi
}

# Idempotent, best-effort, local-only setup for a target project: registers
# the project-scoped skill (writes files only inside $workspace, no system
# change, no account touched) and builds a code-only graph if one doesn't
# exist yet. `--code-only` needs no LLM/API key (tree-sitter AST only), so
# this is safe to run automatically without asking the user for anything —
# see docs/upstream-findings.md "gerar na primeira necessidade".
graph_ensure_ready() {
  local workspace="$1"
  graph_available || return 1

  if [ ! -f "$workspace/.claude/skills/graphify/SKILL.md" ]; then
    echo "graph: registering the graphify skill for this project" >&2
    ( cd "$workspace" && graph_run install --project ) >&2 || {
      echo "graph: skill registration failed, continuing without it" >&2
      return 1
    }
  fi

  if [ ! -f "$(graph_json_path "$workspace")" ]; then
    echo "graph: building an initial code-only graph (local, no API key)" >&2
    ( cd "$workspace" && graph_run extract . --code-only --no-viz ) >&2 || {
      echo "graph: initial graph build failed, continuing without it" >&2
      return 1
    }
  fi
}

graph_is_ready() {
  local workspace="$1"
  graph_available && [ -f "$(graph_json_path "$workspace")" ]
}

# graph_query <workspace> <question> [max_chars]
# Prints a scoped subgraph answer, truncated to max_chars. Returns 1 (with
# no output) when graphify or the graph itself isn't available — callers
# must treat that as "fall back to LSP/rg/direct read", never as an error.
graph_query() {
  local workspace="$1" question="$2"
  local max_chars="${3:-$(policy_get "$_GRAPH_POLICY" graph max_chars 8000)}"
  graph_is_ready "$workspace" || return 1

  local out
  if ! out="$(graph_run query "$question" --graph "$(graph_json_path "$workspace")" 2>/dev/null)"; then
    echo "graph: query failed, falling back" >&2
    return 1
  fi
  printf '%s' "$out" | head -c "$max_chars"
}

graph_explain() {
  local workspace="$1" node="$2"
  local max_chars="${3:-$(policy_get "$_GRAPH_POLICY" graph max_chars 8000)}"
  graph_is_ready "$workspace" || return 1
  local out
  if ! out="$(graph_run explain "$node" --graph "$(graph_json_path "$workspace")" 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$out" | head -c "$max_chars"
}
