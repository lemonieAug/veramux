#!/usr/bin/env bash
# P3.15: the claude-mem cost-optimization experiment harness (lib/memexp.sh).
# Opt-in, deterministic scoring, NEVER mutates claude-mem config. No LLM.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/memexp.sh"
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude-mem"

# --- fixtures ---
assert_eq "10" "$(memexp_facts | grep -c .)" "10 A/B facts ship"
assert_eq "10" "$(memexp_queries | grep -c .)" "10 A/B queries ship"

# --- baseline redacts secrets ---
cat > "$HOME/.claude-mem/settings.json" <<'EOF'
{ "CLAUDE_MEM_PROVIDER": "openrouter", "CLAUDE_MEM_OPENROUTER_API_KEY": "sk-VERY-secret", "model": "haiku" }
EOF
b="$(memexp_baseline)"
assert_contains "$b" '"CLAUDE_MEM_PROVIDER": "openrouter"' "baseline shows the non-secret provider"
assert_contains "$b" '"CLAUDE_MEM_OPENROUTER_API_KEY": "<present>"' "baseline redacts the api key to <present>"
assert_not_contains "$b" "sk-VERY-secret" "baseline never prints the key value"

# --- scoring ---
# a perfect answer sheet: echo back a fragment that matches each expected pattern
: > "$TMP/perfect.txt"
while IFS=$'\t' read -r q pat; do
  [ -n "$q" ] || continue
  printf '%s\n' "${pat%%|*}" >> "$TMP/perfect.txt"
done < <(memexp_queries)
out="$(memexp_score "$TMP/perfect.txt")"; rc=$?
assert_eq "0" "$rc" "a perfect answer sheet scores full recall"
assert_contains "$out" "recall: 10/10" "full recall is reported"

# a sheet that misses half
: > "$TMP/half.txt"
i=0
while IFS=$'\t' read -r q pat; do
  [ -n "$q" ] || continue
  if [ $((i % 2)) -eq 0 ]; then printf '%s\n' "${pat%%|*}" >> "$TMP/half.txt"; else echo "no idea" >> "$TMP/half.txt"; fi
  i=$((i + 1))
done < <(memexp_queries)
out="$(memexp_score "$TMP/half.txt")"; rc=$?
assert_eq "1" "$rc" "a partial answer sheet does not score full recall"
assert_contains "$out" "recall: 5/10" "partial recall is counted correctly"

# --- compare: candidate no worse -> recommend consideration; worse -> do not switch ---
out="$(memexp_compare "$TMP/perfect.txt" "$TMP/perfect.txt")"
assert_contains "$out" "at least as good" "an equal candidate is recommended for consideration"
out="$(memexp_compare "$TMP/perfect.txt" "$TMP/half.txt")"
assert_contains "$out" "do NOT switch" "a candidate that loses recall is rejected"

# --- the harness NEVER touches claude-mem settings ---
before="$(cat "$HOME/.claude-mem/settings.json")"
memexp_baseline >/dev/null; memexp_report >/dev/null; memexp_score "$TMP/perfect.txt" >/dev/null
after="$(cat "$HOME/.claude-mem/settings.json")"
assert_eq "$before" "$after" "no memexp command modifies ~/.claude-mem/settings.json"

report_and_exit
