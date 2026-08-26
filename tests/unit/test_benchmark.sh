#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_exit_code 1 "missing run_dir is an error" bash "$ROOT_DIR/scripts/benchmark.sh" /no/such/dir
assert_exit_code 1 "no argument prints usage and exits 1" bash "$ROOT_DIR/scripts/benchmark.sh"

# A minimal synthetic run_dir, built by hand so this test needs neither a
# real dsh install nor a full orchestrate_run.
RUN_DIR="$TMP/agent-run.fake"
mkdir -p "$RUN_DIR"
cat > "$RUN_DIR/context.md" <<'EOF'
## Memory (past work on this project)

some memory text

## Possibly relevant source (direct search — no graph available)

some snippet
EOF
echo "MEDIUM — an ordinary application-logic change." > "$RUN_DIR/risk.txt"
echo '{"verdict":"approved","summary":"ok","findings":[]}' > "$RUN_DIR/review-1.json"
echo '{"commands":["test: npm test"],"passed":["test: npm test"],"failed":[],"skipped":[]}' > "$RUN_DIR/validation.json"

out="$(bash "$ROOT_DIR/scripts/benchmark.sh" "$RUN_DIR")"
assert_contains "$out" '"risk_tier":"medium"' "risk tier is read from risk.txt"
assert_contains "$out" '"memory":true' "memory section detected"
assert_contains "$out" '"grep_fallback":true' "grep fallback section detected"
assert_contains "$out" '"graph":false' "graph section correctly absent"
assert_contains "$out" '"reviewer_invocations":1' "one reviewer invocation counted"
assert_contains "$out" '"correction_rounds":0' "no correction rounds for a first-round approval"

if command -v node >/dev/null 2>&1; then
  echo "$out" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' >/dev/null 2>&1
  assert_eq "0" "$?" "benchmark output is valid JSON"
else
  echo "SKIP: node not available to validate JSON shape"
fi

report_and_exit
