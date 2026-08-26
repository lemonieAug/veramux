#!/usr/bin/env bash
# Tiny shared test helpers. No framework — see README "Segurança"/style notes
# on avoiding dependencies for things this small.
#
# Deliberately NOT `set -e`: this file is sourced (not run in a subshell)
# into every test_*.sh, and tests routinely need to run a command that is
# EXPECTED to fail and inspect its exit code — `set -e` would abort the
# whole test file the instant such a command returned nonzero, before the
# assertion ever ran. Individual test_*.sh files choose their own flags.
set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$(cd "$UNIT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: ${msg:-assert_eq}: expected [$expected], got [$actual]" >&2
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: ${msg:-assert_contains}: expected to find [$needle]" >&2
    echo "--- haystack ---" >&2
    printf '%s\n' "$haystack" >&2
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: ${msg:-assert_not_contains}: did not expect to find [$needle]" >&2
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

assert_exit_code() {
  local expected="$1" msg="$2"; shift 2
  local actual=0
  "$@" >/tmp/assert_exit_code.out 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: $msg: expected exit $expected, got $actual" >&2
    cat /tmp/assert_exit_code.out >&2
  fi
}

report_and_exit() {
  echo "$(basename "$0"): $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" -eq 0 ]
}

# Copies tests/fixtures/sample-node-project into $1 and makes it a git repo
# with one initial commit, so tests start from a clean, tracked baseline.
make_node_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -r "$TESTS_DIR/fixtures/sample-node-project/." "$dir/"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=test@example.com -c user.name=test add -A
  git -C "$dir" -c user.email=test@example.com -c user.name=test commit -q -m init
}

# Prepends the mock dsh to PATH for the current shell and exports the mode.
use_mock_dsh() {
  local mode="$1"
  export MOCK_DSH_MODE="$mode"
  export PATH="$TESTS_DIR/fixtures/mock-dsh:$PATH"
}

run_agent() {
  bash "$ROOT_DIR/bin/agent" "$@"
}
