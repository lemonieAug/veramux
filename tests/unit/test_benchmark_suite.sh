#!/usr/bin/env bash
# P3.12/P3.13: the offline benchmark suite + regression detector
# (lib/benchmark.sh). Zero LLM, zero quota.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
for m in policy environment redact graph memory research context risk \
         version_drift compat capability_probe inventory state_paths \
         run_lifecycle journal project project_config validation benchmark; do
  source "$ROOT_DIR/lib/$m.sh"
done
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

# --- the shipped fixtures cover categories A-H ---
ids="$(benchmark_fixture_ids)"
assert_eq "8" "$(printf '%s\n' "$ids" | grep -c .)" "8 benchmark fixtures ship"
for cat_id in trivial-doc-typo cart-negative-qty discount-tax-bug retry-queue-cap \
              session-timing-attack fetch-v3-migration notification-refactor-cont planted-sql-injection; do
  assert_contains "$ids" "$cat_id" "fixture $cat_id is present"
done

# --- a single offline run is deterministic and LLM-free ---
row="$(benchmark_run_offline session-timing-attack)"
assert_contains "$row" '"risk":"high"' "an auth/session task classifies HIGH"
assert_contains "$row" '"review_decision":"verify"' "HIGH risk routes to verify"
assert_contains "$row" '"passed":true' "the high-risk fixture matches its expectations"

row2="$(benchmark_run_offline trivial-doc-typo)"
assert_contains "$row2" '"risk":"low"' "a docs-only task classifies LOW"
assert_contains "$row2" '"review_decision":"skip"' "LOW risk skips review"
assert_contains "$row2" '"llm_calls_min":1' "a skipped review means only the lead call is expected"

row3="$(benchmark_run_offline fetch-v3-migration)"
assert_contains "$row3" '"research_routed":true' "a 'migration guide' task routes research"

# --- the whole suite passes and writes a results file ---
out="$(benchmark_suite --offline 2>/dev/null)"; rc=$?
assert_eq "0" "$rc" "the offline suite passes on the shipped config"
assert_contains "$out" "8/8 fixtures" "all 8 fixtures match"
assert_contains "$out" "zero LLM calls" "the suite states it used no quota"
results_file="$(ls -1 "$TMP/state/benchmark"/*offline.json 2>/dev/null | head -1)"
assert_eq "1" "$([ -f "$results_file" ] && echo 1 || echo 0)" "a results file was written"

# --- regression detector ---
cp "$results_file" "$TMP/baseline.json"

# identical -> no findings
out="$(benchmark_compare "$TMP/baseline.json" "$results_file" 2>&1)"; rc=$?
assert_eq "0" "$rc" "an unchanged candidate is not a regression"
assert_contains "$out" "no regressions" "identical results compare clean"

# candidate that doubles a context budget and skips a HIGH review -> hard fail
node -e '
  const fs = require("fs")
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  for (const r of j.results) {
    r.context_budget_chars = r.context_budget_chars * 3
    if (r.fixture === "session-timing-attack") { r.review_decision = "skip"; r.passed = false }
  }
  fs.writeFileSync(process.argv[2], JSON.stringify(j))
' "$TMP/baseline.json" "$TMP/bad-candidate.json"

out="$(benchmark_compare "$TMP/baseline.json" "$TMP/bad-candidate.json" 2>&1)"; rc=$?
assert_eq "1" "$rc" "a regressed candidate fails the comparison"
assert_contains "$out" "HIGH risk routed to skip" "the detector catches a HIGH-risk review being skipped"
assert_contains "$out" "context budget" "the detector catches a context-budget blow-up"

# a candidate that only SHRINKS context is fine (an improvement, not a regression)
node -e '
  const fs = require("fs")
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  for (const r of j.results) r.context_budget_chars = Math.floor(r.context_budget_chars / 2)
  fs.writeFileSync(process.argv[2], JSON.stringify(j))
' "$TMP/baseline.json" "$TMP/lean-candidate.json"
out="$(benchmark_compare "$TMP/baseline.json" "$TMP/lean-candidate.json" 2>&1)"; rc=$?
assert_eq "0" "$rc" "a leaner candidate is not a regression"
assert_contains "$out" "improvement" "a context reduction is reported as an improvement"

report_and_exit
