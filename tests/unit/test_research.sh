#!/usr/bin/env bash
# Unit tests never hit the real network (Jina Reader/search) — see
# tests/fixtures/mock-curl. Real-network behavior belongs in the gated
# integration smoke test, same principle as tests/integration/run.sh for
# Claude/Codex.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/research.sh"
set +e

# --- research_needed: deterministic, no network involved ---
research_needed "Implement rate limiting in this API"
assert_eq "1" "$?" "an ordinary local task does not need research"

research_needed "Fix the null pointer in add.js"
assert_eq "1" "$?" "a routine bugfix does not need research"

research_needed "What does the latest version of Express recommend for rate limiting?"
assert_eq "0" "$?" "a 'latest version' question needs research"

research_needed "Check the official docs for the correct configuration"
assert_eq "0" "$?" "an explicit 'official docs' request needs research"

research_needed "See https://example.com/spec for details"
assert_eq "0" "$?" "a task containing a URL needs research"

# --- fetch/search, mocked curl only (no real network in unit tests) ---
export PATH="$ROOT_DIR/tests/fixtures/mock-curl:$PATH"

result="$(research_fetch_url "https://example.com/docs" 500)"
assert_contains "$result" "MOCK PAGE CONTENT" "fetch_url returns the (mocked) page content"

truncated="$(research_fetch_url "https://example.com/docs" 4)"
assert_eq "4" "${#truncated}" "fetch_url output is truncated to max_chars"

search_result="$(research_search "rate limiting best practices" 5 500)"
assert_contains "$search_result" "MOCK SEARCH RESULT" "search returns (mocked) results"

report_and_exit
