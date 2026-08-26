#!/usr/bin/env bash
# Runs every tests/unit/test_*.sh file. No LLM quota is used — see
# tests/integration/run.sh for the real-product smoke test. Requires
# node/git on PATH (the same hard dependencies as the stack itself).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_pass=0
total_fail=0
any_suite_failed=0

for test_file in "$SELF_DIR"/test_*.sh; do
  echo "== $(basename "$test_file") =="
  if bash "$test_file"; then
    :
  else
    any_suite_failed=1
  fi
  echo
done

if [ "$any_suite_failed" -ne 0 ]; then
  echo "tests/unit: one or more suites failed"
  exit 1
fi
echo "tests/unit: all suites passed"
