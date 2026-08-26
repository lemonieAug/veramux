#!/usr/bin/env bash
# External research (P1.4/P1.8), informed by Agent-Reach's own channel
# choices (Jina Reader for web/search, gh CLI for GitHub — see
# docs/upstream-findings.md) but called directly: Agent-Reach itself has no
# fetch/search subcommand of its own, by design ("a capability layer, not a
# wrapper — the agent calls the upstream tool directly"). Only the safest,
# zero-login channels the spec names (web, search, GitHub) are wired here;
# YouTube/RSS and every login-gated channel (Twitter, Reddit, ...) are left
# to the user asking the lead directly, exactly as Agent-Reach itself
# defaults. This is an optimization: every function degrades to
# "unavailable" instead of failing the run.
set -euo pipefail

_RESEARCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RESEARCH_ROOT_DIR="$(cd "$_RESEARCH_LIB_DIR/.." && pwd)"
_RESEARCH_POLICY="$_RESEARCH_ROOT_DIR/policies/context.yaml"

research_enabled() {
  policy_get_bool "$_RESEARCH_POLICY" external enabled true
}

# research_needed <task>
# Deterministic, keyword/URL-based gate (P1.8): true only when the task
# looks like it actually depends on external/current information. No LLM
# call is used to decide this.
research_needed() {
  local task="$1"
  research_enabled || return 1
  if printf '%s' "$task" | grep -qE 'https?://'; then
    return 0
  fi
  printf '%s' "$task" | grep -qiE \
    '\b(latest|current|newest|up[- ]to[- ]date|changelog|release notes|documentation|docs for|official docs|upstream|CVE|advisory|deprecat(ed|ion)|breaking change|migrat(e|ion) guide|compare|benchmark|according to)\b'
}

research_fetch_url() {
  local url="$1"
  local max_chars="${2:-$(policy_get "$_RESEARCH_POLICY" external max_chars 10000)}"
  env_has_cmd curl || return 1
  local out
  if ! out="$(curl -sfL --max-time 15 "https://r.jina.ai/${url}" 2>/dev/null)"; then
    echo "research: fetch failed for $url, continuing without it" >&2
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out" | head -c "$max_chars"
}

# research_search <query> [max_results] [max_chars]
# Jina's search endpoint (a sibling of the Reader endpoint Agent-Reach's own
# web channel uses): free for light use, no API key required.
research_search() {
  local query="$1"
  local max_results="${2:-$(policy_get "$_RESEARCH_POLICY" external max_results 5)}"
  local max_chars="${3:-$(policy_get "$_RESEARCH_POLICY" external max_chars 10000)}"
  env_has_cmd curl || return 1
  local encoded out
  encoded="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$query")"
  if ! out="$(curl -sfL --max-time 15 -H "X-Respond-With: no-content" "https://s.jina.ai/${encoded}" 2>/dev/null)"; then
    echo "research: search failed, continuing without it" >&2
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out" | head -"$((max_results * 20))" | head -c "$max_chars"
}

research_github() {
  env_has_cmd gh || return 1
  local repo="$1" max_chars="${2:-$(policy_get "$_RESEARCH_POLICY" external max_chars 10000)}"
  local out
  if ! out="$(gh repo view "$repo" 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$out" | head -c "$max_chars"
}
