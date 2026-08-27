#!/usr/bin/env bash
# P3.12/P3.13: the benchmark suite. Two modes:
#
#   --offline  DETERMINISTIC. No Claude/Codex calls, no quota. Exercises the
#              parts of the pipeline our own code owns — risk classification,
#              review routing, context-tool routing, and the context-budget
#              footprint — and checks them against each fixture's expected
#              characteristics. This is what runs in tests and in
#              `agent update` verification.
#
#   --live     Actually runs `agent` against each fixture workspace with the
#              real providers. Spends Claude/Codex usage, so it only ever
#              runs on an explicit `agent benchmark --live`.
#
# Results are written under state_benchmark_dir/ and can be diffed with
# benchmark_compare to catch a quality or token/context regression from a
# config change or an update. Sourced by bin/agent. Must not be executed
# directly.
set -euo pipefail

_BENCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BENCH_ROOT_DIR="$(cd "$_BENCH_LIB_DIR/.." && pwd)"
_BENCH_FIXTURES_DIR="${AGENT_BENCHMARK_FIXTURES:-$_BENCH_ROOT_DIR/tests/benchmark/fixtures}"
_BENCH_POLICY="$_BENCH_ROOT_DIR/policies/benchmark.yaml"

benchmark_fixture_ids() {
  [ -d "$_BENCH_FIXTURES_DIR" ] || return 0
  local d
  for d in "$_BENCH_FIXTURES_DIR"/*/; do
    [ -f "${d}manifest.yaml" ] && basename "$d"
  done
}

_bench_manifest() { policy_get_toplevel "$_BENCH_FIXTURES_DIR/$1/manifest.yaml" "$2" "${3:-}"; }

# _bench_prepare_workspace <fixture> -> prints a fresh temp workspace path
# Each fixture ships a files/ tree (committed as the base) plus a manifest
# `changed_paths` list. Those paths are left with an uncommitted edit so
# risk classification / diff logic see exactly the surface a solution to
# the task would touch — without running any model.
_bench_prepare_workspace() {
  local fixture="$1" src="$_BENCH_FIXTURES_DIR/$1/files" ws
  ws="$(mktemp -d "${TMPDIR:-/tmp}/agent-bench-$fixture.XXXXXX")"
  [ -d "$src" ] && cp -r "$src/." "$ws/"
  git -C "$ws" init -q 2>/dev/null || true
  git -C "$ws" add -A 2>/dev/null || true
  git -C "$ws" -c user.email=b@b -c user.name=b commit -q -m base 2>/dev/null || true

  local cp_list p
  cp_list="$(_bench_manifest "$fixture" changed_paths)"
  for p in $(printf '%s' "$cp_list" | tr ',' ' '); do
    [ -n "$p" ] || continue
    mkdir -p "$ws/$(dirname "$p")"
    printf '\n// benchmark: simulated edit surface for this task\n' >> "$ws/$p"
  done
  printf '%s\n' "$ws"
}

# _bench_review_decision <risk> <always_review:0|1> -> skip | review | verify
_bench_review_decision() {
  local risk="$1" always="$2"
  if [ "$risk" = "low" ] && [ "$always" -eq 0 ] && ! risk_requires_codex low; then
    echo "skip"; return 0
  fi
  if risk_requires_verification "$risk"; then echo "verify"; return 0; fi
  echo "review"
}

# _bench_context_budget <memory:0|1> <graph:0|1> <research:0|1>
# The deterministic context-size proxy: the sum of the per-section char
# budgets from policies/context.yaml for the sections that WOULD be
# consulted. Not a token count — a stable, config-driven footprint number
# (same philosophy as scripts/benchmark.sh).
_bench_context_budget() {
  local mem="$1" graph="$2" research="$3" total=0 ctx="$_BENCH_ROOT_DIR/policies/context.yaml"
  local b_src b_mem b_graph b_ext
  b_src="$(policy_get "$ctx" source initial_max_chars 30000)"
  b_mem="$(policy_get "$ctx" memory max_chars 4000)"
  b_graph="$(policy_get "$ctx" graph max_chars 8000)"
  b_ext="$(policy_get "$ctx" external max_chars 10000)"
  # reflect the active P3.14 profile if one is loaded
  if command -v profile_budget >/dev/null 2>&1; then
    b_src="$(profile_budget source_initial_max_chars "$b_src")"
    b_mem="$(profile_budget memory_max_chars "$b_mem")"
    b_graph="$(profile_budget graph_max_chars "$b_graph")"
    b_ext="$(profile_budget external_max_chars "$b_ext")"
    command -v profile_external_enabled >/dev/null 2>&1 && ! profile_external_enabled && research=0
  fi
  total=$b_src
  [ "$mem" -eq 1 ] && total=$(( total + b_mem ))
  [ "$graph" -eq 1 ] && total=$(( total + b_graph ))
  [ "$research" -eq 1 ] && total=$(( total + b_ext ))
  echo "$total"
}

# benchmark_run_offline <fixture>
# Prints one JSON object (the fixture's deterministic result row).
benchmark_run_offline() {
  local fixture="$1"
  local task expected_risk expected_review expected_tools always_review
  task="$(cat "$_BENCH_FIXTURES_DIR/$fixture/task.txt" 2>/dev/null)"
  expected_risk="$(_bench_manifest "$fixture" expected_risk)"
  expected_review="$(_bench_manifest "$fixture" expected_review)"
  expected_tools="$(_bench_manifest "$fixture" expected_tools)"     # comma list: memory,graph,research,none
  always_review="$(_bench_manifest "$fixture" always_review 0)"

  local ws; ws="$(_bench_prepare_workspace "$fixture")"
  local risk; risk="$(risk_classify "$ws" 2>/dev/null || echo medium)"

  # research routing is deterministic (keyword rule). memory/graph are
  # "consulted if the policy enables them" — the P1 default router tries
  # memory first, then graph — so the deterministic footprint counts them
  # whenever policies/context.yaml (or a project override) enables them.
  local research=0; research_needed "$task" && research=1
  local memory=0;  context_memory_enabled "$ws" && memory=1
  local graph=0;   context_graph_enabled "$ws" && graph=1
  rm -rf "$ws"

  local review_decision; review_decision="$(_bench_review_decision "$risk" "$always_review")"
  local budget; budget="$(_bench_context_budget "$memory" "$graph" "$research")"
  local llm_calls_min=1
  [ "$review_decision" != "skip" ] && llm_calls_min=2

  local risk_ok=true review_ok=true tools_ok=true
  [ -n "$expected_risk" ] && [ "$risk" != "$expected_risk" ] && risk_ok=false
  [ -n "$expected_review" ] && [ "$review_decision" != "$expected_review" ] && review_ok=false
  # tool expectation: every tool named in expected_tools (except "none")
  # must be one the router would actually have available/triggered.
  local t
  for t in $(printf '%s' "$expected_tools" | tr ',' ' '); do
    case "$t" in
      none|"") ;;
      memory)   [ "$memory" -eq 1 ]   || tools_ok=false ;;
      graph)    [ "$graph" -eq 1 ]    || tools_ok=false ;;
      research) [ "$research" -eq 1 ] || tools_ok=false ;;
    esac
  done

  local passed=true
  [ "$risk_ok" = true ] && [ "$review_ok" = true ] && [ "$tools_ok" = true ] || passed=false
  # invariant: HIGH risk must never route to skip
  [ "$risk" = "high" ] && [ "$review_decision" = "skip" ] && passed=false

  node "$_BENCH_LIB_DIR/json-tools.mjs" build-object \
    "fixture=$fixture" "mode=offline" \
    "category=$(_bench_manifest "$fixture" category)" \
    "risk=$risk" "expected_risk=$expected_risk" "risk_ok=$risk_ok" \
    "review_decision=$review_decision" "expected_review=$expected_review" "review_ok=$review_ok" \
    "research_routed=$([ "$research" -eq 1 ] && echo true || echo false)" \
    "tools_ok=$tools_ok" \
    "context_budget_chars=$budget" "llm_calls_min=$llm_calls_min" \
    "passed=$passed"
}

# benchmark_run_live <fixture>  (requires real providers; caller gates on --live)
benchmark_run_live() {
  local fixture="$1"
  local ws; ws="$(_bench_prepare_workspace "$fixture")"
  local task; task="$(cat "$_BENCH_FIXTURES_DIR/$fixture/task.txt" 2>/dev/null)"
  local out rc run_dir
  out="$(cd "$ws" && printf '%s' "$task" | "$_BENCH_ROOT_DIR/bin/agent" . 2>&1)"; rc=$?
  run_dir="$(printf '%s\n' "$out" | sed -n 's/^run artifacts: //p' | head -1)"
  local summary='{}'
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && summary="$(bash "$_BENCH_ROOT_DIR/scripts/benchmark.sh" "$run_dir" 2>/dev/null || echo '{}')"
  rm -rf "$ws"
  node "$_BENCH_LIB_DIR/json-tools.mjs" build-object \
    "fixture=$fixture" "mode=live" "exit_code=$rc" \
    "final_line=$(printf '%s\n' "$out" | grep -m1 'FINAL RESULT' | tail -1)" \
    "run_summary=$summary"
}

# benchmark_suite --offline|--live  -> writes a results file, prints a table
benchmark_suite() {
  local mode="${1:---offline}"
  local ts results
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$(state_benchmark_dir)"
  results="$(state_benchmark_dir)/$ts-${mode#--}.json"

  local rows="" id row
  for id in $(benchmark_fixture_ids); do
    if [ "$mode" = "--live" ]; then row="$(benchmark_run_live "$id")"; else row="$(benchmark_run_offline "$id")"; fi
    rows="${rows:+$rows,}$row"
    printf '%s\n' "$row" >&2
  done
  printf '{"schema_version":1,"mode":"%s","ran_at":"%s","results":[%s]}\n' "${mode#--}" "$ts" "$rows" > "$results"

  echo
  if [ "$mode" = "--offline" ]; then
    local total passed
    total="$(benchmark_fixture_ids | grep -c . || true)"
    passed="$(printf '%s' "$rows" | grep -o '"passed":true' | grep -c . || true)"
    echo "offline benchmark: $passed/$total fixtures match their expected characteristics"
    echo "results: $results  (zero LLM calls, zero quota used)"
    [ "$passed" = "$total" ]
  else
    echo "live benchmark complete: $results"
    echo "(this run spent real Claude/Codex usage)"
  fi
}

# benchmark_compare <baseline.json> <candidate.json>
# The P3.13 regression detector. Prints findings; returns nonzero if any
# HARD invariant is broken or a threshold is exceeded without justification.
benchmark_compare() {
  local baseline="$1" candidate="$2"
  [ -f "$baseline" ] && [ -f "$candidate" ] || { echo "error: need two results files" >&2; return 2; }
  local max_calls max_ctx
  max_calls="$(policy_get "$_BENCH_POLICY" thresholds max_llm_call_increase_pct 20)"
  max_ctx="$(policy_get "$_BENCH_POLICY" thresholds max_context_increase_pct 25)"
  node "$_BENCH_LIB_DIR/json-tools.mjs" benchmark-compare "$baseline" "$candidate" "$max_calls" "$max_ctx"
}
