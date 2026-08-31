#!/usr/bin/env bash
# Context package assembly (P1.5/P1.6/P1.7). Builds one small, bounded text
# block from memory (claude-mem), architecture (Graphify), and — only when
# Graphify has nothing — a few directly grepped source snippets. Routing is
# mutually exclusive by design (graph OR direct grep, never both for the
# same need): that is this module's answer to "duplication control" (P1's
# own dedupe ask) rather than a separate post-hoc text-similarity pass.
# Never blocks the run: every source is best-effort and independently
# optional. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_CTX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CTX_ROOT_DIR="$(cd "$_CTX_LIB_DIR/.." && pwd)"
_CTX_POLICY="$_CTX_ROOT_DIR/policies/context.yaml"

_ctx_default_bool() {
  policy_get_bool "$_CTX_POLICY" "$1" "$2" true && echo true || echo false
}

context_memory_enabled() {
  local workspace="$1"
  project_config_bool "$workspace" memory enabled "$(_ctx_default_bool memory enabled)"
}

context_graph_enabled() {
  local workspace="$1"
  project_config_bool "$workspace" graph enabled "$(_ctx_default_bool graph enabled)"
}

context_research_enabled() {
  local workspace="$1"
  project_config_bool "$workspace" research enabled "$(_ctx_default_bool external enabled)"
}

# A handful of direct grep snippets when Graphify has nothing to offer —
# the P1 spec's "direct_reads_before_graph" fallback. Deliberately crude
# (git grep, not a ranking model): pulls out the task's longest words as
# candidate identifiers and shows up to N matching files' first hits.
_context_grep_fallback() {
  local workspace="$1" task="$2"
  local max_files max_chars
  max_files="$(policy_get "$_CTX_POLICY" graph direct_reads_before_graph 3)"
  max_chars="$(policy_get "$_CTX_POLICY" source initial_max_chars 30000)"
  if command -v profile_budget >/dev/null 2>&1; then
    max_chars="$(profile_budget source_initial_max_chars "$max_chars" "$workspace")"
  fi
  env_has_cmd git || return 1

  local -a words
  mapfile -t words < <(printf '%s' "$task" | grep -oE '[A-Za-z_][A-Za-z0-9_]{4,}' | sort -u | head -8)
  [ "${#words[@]}" -eq 0 ] && return 1

  local -a seen_files=()
  local word out file
  local budget="$max_chars"
  for word in "${words[@]}"; do
    [ "${#seen_files[@]}" -ge "$max_files" ] && break
    out="$(git -C "$workspace" grep -n -I -m 1 -- "$word" 2>/dev/null | head -n "$max_files")" || continue
    [ -z "$out" ] && continue
    while IFS= read -r line; do
      [ "${#seen_files[@]}" -ge "$max_files" ] && break
      file="${line%%:*}"
      if [[ ! " ${seen_files[*]-} " == *" $file "* ]]; then
        seen_files+=("$file")
        local snippet
        snippet="$(printf '### %s\n%s\n' "$file" "$line")"
        printf '%s\n\n' "$snippet" | head -c "$budget"
        budget=$((budget - ${#snippet}))
        [ "$budget" -le 0 ] && return 0
      fi
    done <<< "$out"
  done
  [ "${#seen_files[@]}" -gt 0 ]
}

# context_build <workspace> <task> <out_file>
# Always writes out_file (possibly empty) and always returns 0.
context_build() {
  local workspace="$1" task="$2" out_file="$3"
  : > "$out_file"

  # P3.14: an optimization profile (lib/profiles.sh, present only on a real
  # `agent` run) can resize these budgets or turn external research off. It
  # is a no-op when profiles.sh isn't sourced (the P1 suites).
  _ctx_budget() {
    local base; base="$(policy_get "$_CTX_POLICY" "$1" "$2" "$3")"
    if command -v profile_budget >/dev/null 2>&1; then profile_budget "$4" "$base" "$workspace"; else printf '%s' "$base"; fi
  }

  if context_memory_enabled "$workspace"; then
    local memory_max
    memory_max="$(_ctx_budget memory max_chars 4000 memory_max_chars)"
    local memory_text
    if memory_text="$(memory_search "$workspace" "$task" "$memory_max")" && [ -n "$memory_text" ]; then
      { echo "## Memory (past work on this project)"; echo; echo "$memory_text"; echo; } >> "$out_file"
    fi
  fi

  local graph_added=0
  if context_graph_enabled "$workspace"; then
    local graph_max
    graph_max="$(_ctx_budget graph max_chars 8000 graph_max_chars)"
    local graph_text
    if graph_text="$(graph_query "$workspace" "$task" "$graph_max")" && [ -n "$graph_text" ]; then
      { echo "## Architecture (knowledge graph)"; echo; echo "$graph_text"; echo; } >> "$out_file"
      graph_added=1
    fi
  fi

  if [ "$graph_added" -eq 0 ]; then
    local grep_text
    if grep_text="$(_context_grep_fallback "$workspace" "$task")" && [ -n "$grep_text" ]; then
      { echo "## Possibly relevant source (direct search — no graph available)"; echo; echo "$grep_text"; } >> "$out_file"
    fi
  fi

  if context_research_enabled "$workspace" && research_needed "$task" \
     && { ! command -v profile_external_enabled >/dev/null 2>&1 || profile_external_enabled "$workspace"; }; then
    local ext_max ext_text url
    ext_max="$(_ctx_budget external max_chars 10000 external_max_chars)"
    url="$(printf '%s' "$task" | grep -oE 'https?://[^[:space:]]+' | head -1)"
    if [ -n "$url" ]; then
      ext_text="$(research_fetch_url "$url" "$ext_max" || true)"
    else
      ext_text="$(research_search "$task" "" "$ext_max" || true)"
    fi
    if [ -n "$ext_text" ]; then
      { echo "## External research"; echo; echo "$ext_text"; echo; } >> "$out_file"
    fi
  fi

  return 0
}
