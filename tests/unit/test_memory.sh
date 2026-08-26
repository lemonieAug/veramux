#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/memory.sh"
set +e

TMP="$(mktemp -d)"
cleanup() { stop_mock_memory_server; rm -rf "$TMP"; }
trap cleanup EXIT

git -C "$TMP" init -q 2>/dev/null
mkdir -p "$TMP"

# Before the worker is up: unavailable, never an error.
CLAUDE_MEM_WORKER_PORT=37799
export CLAUDE_MEM_WORKER_PORT
if memory_available; then r=0; else r=1; fi
assert_eq "1" "$r" "no worker running -> unavailable"
if memory_search "$TMP" "why does the rate limiter break under concurrent load" 200; then r=0; else r=1; fi
assert_eq "1" "$r" "search falls back cleanly when the worker is down"

if ! start_mock_memory_server 37799; then
  echo "SKIP: could not start mock memory server (node/curl unavailable) — remaining assertions skipped"
  report_and_exit
  exit $?
fi

memory_available
assert_eq "0" "$?" "worker up -> available"

result="$(memory_search "$TMP" "why does the rate limiter break under concurrent load in prod" 500)"
assert_contains "$result" "Relevant Past Work" "search returns the mock backend's context block"

memory_search "$TMP" "short" 500
assert_eq "1" "$?" "a too-short query hits upstream's own relevance gate and returns nothing"

truncated="$(memory_search "$TMP" "why does the rate limiter break under concurrent load in prod" 10)"
assert_eq "10" "${#truncated}" "search output is truncated to max_chars"

report_and_exit
