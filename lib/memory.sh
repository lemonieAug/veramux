#!/usr/bin/env bash
# claude-mem integration (P1.3). claude-mem runs a local HTTP worker service;
# its /api/context/semantic endpoint is a direct, bash-callable equivalent of
# the MCP search tool it gives Claude — see docs/upstream-findings.md. This
# is an optimization, never a hard dependency: every function degrades to
# "unavailable" instead of failing the run when claude-mem isn't installed
# or its worker isn't up.
set -euo pipefail

_MEM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEM_ROOT_DIR="$(cd "$_MEM_LIB_DIR/.." && pwd)"
_MEM_POLICY="$_MEM_ROOT_DIR/policies/context.yaml"

# Matches claude-mem's own per-OS-user default (37700 + uid % 100), so we
# find the same worker it would find, without needing its settings.json.
memory_worker_port() {
  if [ -n "${CLAUDE_MEM_WORKER_PORT:-}" ]; then
    printf '%s' "$CLAUDE_MEM_WORKER_PORT"
    return
  fi
  local uid
  uid="$(id -u 2>/dev/null || echo 0)"
  printf '%s' "$((37700 + uid % 100))"
}

memory_worker_url() {
  printf 'http://127.0.0.1:%s' "$(memory_worker_port)"
}

memory_available() {
  env_has_cmd curl || return 1
  curl -sf --max-time 2 "$(memory_worker_url)/api/health" >/dev/null 2>&1
}

# claude-mem derives a project's identity from its git repo root's basename
# (falls back to the cwd basename outside a repo) — see
# docs/upstream-findings.md. Matching that here means our query lands on the
# same project bucket claude-mem itself would use.
memory_project_name() {
  local workspace="$1" root
  if root="$(git -C "$workspace" rev-parse --show-toplevel 2>/dev/null)"; then
    basename "$root"
  else
    basename "$workspace"
  fi
}

# memory_search <workspace> <query> [max_chars]
# Prints a compact, pre-formatted markdown block of relevant past
# observations, truncated to max_chars. Returns 1 (no output) when the
# worker is unavailable or the query is too short for claude-mem's own
# relevance gate (it silently returns empty context under ~20 chars) —
# callers must treat that as "no memory to inject", never as an error.
memory_search() {
  local workspace="$1" query="$2"
  local max_chars="${3:-$(policy_get "$_MEM_POLICY" memory max_chars 4000)}"
  local limit
  limit="$(policy_get "$_MEM_POLICY" memory max_results 5)"
  memory_available || return 1

  local project body response context
  project="$(memory_project_name "$workspace")"
  body="$(node -e '
    const [q, project, limit] = process.argv.slice(1)
    process.stdout.write(JSON.stringify({ q, project, limit: Number(limit) }))
  ' "$query" "$project" "$limit")"

  if ! response="$(curl -sf --max-time 5 -X POST "$(memory_worker_url)/api/context/semantic" \
      -H 'Content-Type: application/json' -d "$body" 2>/dev/null)"; then
    echo "memory: worker request failed, continuing without memory" >&2
    return 1
  fi

  context="$(printf '%s' "$response" | node "$_MEM_LIB_DIR/json-tools.mjs" get-field context)"
  [ -n "$context" ] || return 1
  printf '%s' "$context" | head -c "$max_chars"
}
