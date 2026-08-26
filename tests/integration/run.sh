#!/usr/bin/env bash
# Real end-to-end smoke test (P0.15): actually calls the lead (Claude Code)
# and reviewer (Codex) profiles through a real `dsh` install. This spends
# real quota / usage against your Claude and Codex accounts, so it never
# runs automatically — only:
#
#   RUN_LLM_INTEGRATION_TESTS=1 ./tests/integration/run.sh
#
# Prerequisites: `agent doctor` passes (dsh installed, both profiles
# configured, Claude Code and Codex authenticated).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "${RUN_LLM_INTEGRATION_TESTS:-}" != "1" ]; then
  echo "skipped: set RUN_LLM_INTEGRATION_TESTS=1 to run this (it spends real Claude/Codex usage)."
  exit 0
fi

echo "== doctor precheck =="
if ! bash "$ROOT_DIR/scripts/doctor.sh"; then
  echo "error: 'agent doctor' is not clean; fix that before running the real smoke test." >&2
  exit 1
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PROJECT="$TMP/sample-node-project"
cp -r "$ROOT_DIR/tests/fixtures/sample-node-project" "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=smoke@example.com -c user.name=smoke add -A
git -C "$PROJECT" -c user.email=smoke@example.com -c user.name=smoke commit -q -m init

echo "== running: agent on the P0.15 sample task =="
echo "project: $PROJECT"

set +e
bash "$ROOT_DIR/bin/agent" "$PROJECT" \
  "Add validation to prevent negative numbers in the add() function in add.js. It should throw a clear error instead of returning an incorrect result."
code=$?
set -e

echo
echo "== resulting diff =="
git -C "$PROJECT" --no-pager diff HEAD || true

echo
if [ "$code" -eq 0 ]; then
  echo "smoke test: agent finished successfully."
else
  echo "smoke test: agent finished with exit $code (see FINAL RESULT above — this may be a legitimate blocked/failed outcome, not a script bug)."
fi
exit "$code"
