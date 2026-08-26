#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JT="$ROOT_DIR/lib/json-tools.mjs"

# valid, empty findings
echo '{"verdict":"approved","summary":"ok","findings":[]}' > "$TMP/valid.json"
assert_exit_code 0 "valid minimal review is accepted" node "$JT" validate-review "$TMP/valid.json"

# valid with one finding
cat > "$TMP/valid2.json" <<'EOF'
{"verdict":"changes_requested","summary":"issue","findings":[{"severity":"high","category":"security","file":"a.js","line":10,"problem":"p","reason":"r","recommendation":"rec"}]}
EOF
assert_exit_code 0 "valid review with a finding is accepted" node "$JT" validate-review "$TMP/valid2.json"

# malformed JSON
echo 'not json at all' > "$TMP/bad1.json"
assert_exit_code 1 "malformed JSON is rejected" node "$JT" validate-review "$TMP/bad1.json"

# invalid verdict
echo '{"verdict":"maybe","summary":"x","findings":[]}' > "$TMP/bad2.json"
assert_exit_code 1 "invalid verdict value is rejected" node "$JT" validate-review "$TMP/bad2.json"

# missing summary
echo '{"verdict":"approved","findings":[]}' > "$TMP/bad3.json"
assert_exit_code 1 "missing summary is rejected" node "$JT" validate-review "$TMP/bad3.json"

# findings not an array
echo '{"verdict":"approved","summary":"x","findings":"none"}' > "$TMP/bad4.json"
assert_exit_code 1 "non-array findings is rejected" node "$JT" validate-review "$TMP/bad4.json"

# invalid severity
echo '{"verdict":"approved","summary":"x","findings":[{"severity":"urgent","category":"other","file":null,"line":null,"problem":"p","reason":"r","recommendation":"rec"}]}' > "$TMP/bad5.json"
assert_exit_code 1 "invalid severity is rejected" node "$JT" validate-review "$TMP/bad5.json"

# approved contradicted by a critical finding
echo '{"verdict":"approved","summary":"x","findings":[{"severity":"critical","category":"security","file":null,"line":null,"problem":"p","reason":"r","recommendation":"rec"}]}' > "$TMP/bad6.json"
assert_exit_code 1 "approved with a critical finding is rejected" node "$JT" validate-review "$TMP/bad6.json"

# blocking-findings filters correctly
cat > "$TMP/mixed.json" <<'EOF'
{"verdict":"changes_requested","summary":"x","findings":[
  {"severity":"low","category":"maintainability","file":null,"line":null,"problem":"p1","reason":"r1","recommendation":"rec1"},
  {"severity":"critical","category":"security","file":"a.js","line":1,"problem":"p2","reason":"r2","recommendation":"rec2"},
  {"severity":"medium","category":"tests","file":null,"line":null,"problem":"p3","reason":"r3","recommendation":"rec3"}
]}
EOF
node "$JT" blocking-findings "$TMP/mixed.json" > "$TMP/blocking.json"
count="$(node "$JT" findings-count "$TMP/blocking.json")"
assert_eq "1" "$count" "only critical/high findings are blocking"

report_and_exit
