#!/usr/bin/env bash
# End-to-end bin/agent runs against the mock dsh (tests/fixtures/mock-dsh).
# No LLM quota is spent — see tests/integration/run.sh for the real-product
# smoke test, gated behind RUN_LLM_INTEGRATION_TESTS=1.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) happy path: approved on the first round
use_mock_dsh happy
make_node_fixture "$TMP/happy"
out="$(run_agent "$TMP/happy" "Add validation to prevent negative numbers." 2>&1)"
code=$?
assert_eq "0" "$code" "happy path exits 0"
assert_contains "$out" "FINAL RESULT: approved" "happy path reports approved"

# 2) correction loop: round 1 fails validation + review, round 2 fixes and approves
use_mock_dsh changes_then_approve
make_node_fixture "$TMP/correction"
out="$(run_agent "$TMP/correction" "Add validation to prevent negative numbers." 2>&1)"
code=$?
assert_eq "0" "$code" "correction loop eventually exits 0"
assert_contains "$out" "Claude correction (round 1)" "a correction round actually ran"
assert_contains "$out" "FINAL RESULT: approved (round 2)" "second round is the one that approves"

# 3) invalid JSON once: one retry recovers
use_mock_dsh invalid_json_once
make_node_fixture "$TMP/badjson1"
out="$(run_agent "$TMP/badjson1" "task" 2>&1)"
code=$?
assert_eq "0" "$code" "one retry after invalid JSON still succeeds"
assert_contains "$out" "did not match the required JSON contract" "invalid JSON is reported, not silently ignored"

# 4) invalid JSON twice: no second retry, reported as failure
use_mock_dsh invalid_json_twice
make_node_fixture "$TMP/badjson2"
out="$(run_agent "$TMP/badjson2" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "invalid JSON on the retry too is a failure, not a masked success"
assert_contains "$out" "did not return a valid response after one retry" "clear message on repeated invalid JSON"

# 5) max correction rounds: still blocking after policy limit -> failure, not success
use_mock_dsh never_approves
make_node_fixture "$TMP/neverapproves"
out="$(run_agent "$TMP/neverapproves" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "exceeding max_correction_rounds is a failure"
assert_contains "$out" "FINAL RESULT: blocked" "blocked outcome is reported explicitly"
assert_not_contains "$out" "FINAL RESULT: approved" "a still-blocked run must never claim approval"

# 6) Claude (lead) unavailable
use_mock_dsh lead_unreachable
make_node_fixture "$TMP/leaddown"
out="$(run_agent "$TMP/leaddown" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "lead unreachable is a failure"
assert_contains "$out" "could not reach the lead" "clear message when Claude is unavailable"

# 7) Codex (reviewer) unavailable
use_mock_dsh reviewer_unreachable
make_node_fixture "$TMP/reviewerdown"
out="$(run_agent "$TMP/reviewerdown" "task" 2>&1)"
code=$?
assert_eq "1" "$code" "reviewer unreachable is a failure"
assert_contains "$out" "could not reach the reviewer" "clear message when Codex is unavailable"

# 8) docs-only change skips review entirely, even for a brand-new file
use_mock_dsh docs_only
make_node_fixture "$TMP/docsonly"
out="$(run_agent "$TMP/docsonly" "Add a NOTES.md file." 2>&1)"
code=$?
assert_eq "0" "$code" "docs-only change exits 0"
assert_contains "$out" "skipping Codex review per policy" "docs-only skip is explicit"
assert_not_contains "$out" "Codex review (round" "docs-only change never calls the reviewer"

report_and_exit
