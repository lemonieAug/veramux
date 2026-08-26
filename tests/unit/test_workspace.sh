#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/project.sh"
# lib/project.sh sets -e for production use; this test needs to inspect the
# exit codes of calls that are expected to fail, so turn it back off here.
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) resolves an existing directory to an absolute path
mkdir -p "$TMP/proj"
resolved="$(project_resolve_workspace "$TMP/proj")"
assert_eq "$(cd "$TMP/proj" && pwd)" "$resolved" "resolves existing directory"

# 2) nonexistent path is an error
if project_resolve_workspace "$TMP/does-not-exist" >/tmp/ws.out 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: nonexistent path should have failed" >&2
else
  PASS_COUNT=$((PASS_COUNT + 1))
fi
assert_contains "$(cat /tmp/ws.out)" "does not exist" "nonexistent path error message"

# 3) a file (not a directory) is rejected
touch "$TMP/afile"
if project_resolve_workspace "$TMP/afile" >/tmp/ws2.out 2>&1; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: a plain file should have been rejected as workspace" >&2
else
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# 4) full `agent` run against a non-git directory fails loudly (not silently)
use_mock_dsh happy
mkdir -p "$TMP/nogit"
cp -r "$ROOT_DIR/tests/fixtures/sample-node-project/." "$TMP/nogit/"
assert_exit_code 1 "agent on a non-git repo exits 1" run_agent "$TMP/nogit" "do something"
out="$(run_agent "$TMP/nogit" "do something" 2>&1 || true)"
assert_contains "$out" "not a git repository" "non-git error is explicit"

report_and_exit
