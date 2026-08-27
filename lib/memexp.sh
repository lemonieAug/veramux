#!/usr/bin/env bash
# P3.15: claude-mem cost-optimization EXPERIMENT harness. Entirely opt-in.
#
# claude-mem can run its background memory compression against different
# providers / auth modes (subscription, api-key, a LiteLLM-style gateway,
# or a small local model behind one). The question this harness helps
# answer: can a cheaper compressor keep recall good enough?
#
# What this module does NOT do: it never changes ~/.claude-mem/settings.json,
# never enables a gateway, never installs a local model, never buys API
# access. It records the current config (secrets redacted), ships a fixed
# 10-fact / 10-query A/B set, scores recall deterministically, and prints a
# RECOMMENDATION. Switching providers stays a manual, explicit decision.
#
# No LLM is called by this module itself. Sourced by bin/agent. Must not be
# executed directly.
set -euo pipefail

_MEMEXP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMEXP_ROOT_DIR="$(cd "$_MEMEXP_LIB_DIR/.." && pwd)"
_MEMEXP_FIXTURES="${AGENT_MEMEXP_FIXTURES:-$_MEMEXP_ROOT_DIR/tests/benchmark/memory}"

memexp_facts()   { cat "$_MEMEXP_FIXTURES/facts.txt" 2>/dev/null; }
memexp_queries() { cat "$_MEMEXP_FIXTURES/queries.tsv" 2>/dev/null; }

# memexp_baseline
# The current claude-mem compressor configuration, with any secret value
# redacted to a boolean "present/absent".
memexp_baseline() {
  local s="$HOME/.claude-mem/settings.json"
  if [ ! -f "$s" ]; then echo "claude-mem is not configured on this machine (no ~/.claude-mem/settings.json)"; return 0; fi
  node -e '
    const fs = require("fs")
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const secret = /key|token|secret|password|cookie/i
    const view = {}
    for (const [k, v] of Object.entries(j)) {
      view[k] = secret.test(k) ? (v ? "<present>" : "<absent>") : v
    }
    process.stdout.write(JSON.stringify(view, null, 2))
  ' "$s" 2>/dev/null || echo "(could not parse settings.json)"
}

# memexp_score <recall-output-file>
# recall-output-file: one line per query, the answer text a candidate
# configuration produced (same order as queries.tsv). Prints
# "<hits>/<total>" and the per-query verdicts; returns 0 iff every query hit.
memexp_score() {
  local answers="$1"
  [ -f "$answers" ] || { echo "usage: memexp_score <answers-file>" >&2; return 2; }
  local total=0 hits=0 line q pat ans i=0
  mapfile -t _ans < "$answers"
  while IFS=$'\t' read -r q pat; do
    [ -n "$q" ] || continue
    total=$((total + 1))
    ans="${_ans[$i]:-}"; i=$((i + 1))
    if printf '%s' "$ans" | grep -qiE "($pat)"; then
      hits=$((hits + 1)); echo "  HIT  $q"
    else
      echo "  MISS $q  (expected /$pat/, got: ${ans:0:60})"
    fi
  done < <(memexp_queries)
  echo "recall: $hits/$total"
  [ "$hits" -eq "$total" ]
}

# memexp_compare <baseline-answers> <candidate-answers>
memexp_compare() {
  local b="$1" c="$2"
  echo "baseline:"; memexp_score "$b" | sed 's/^/  /'; local br=$?
  echo "candidate:"; memexp_score "$c" | sed 's/^/  /'; local cr=$?
  local bh ch
  bh="$(memexp_score "$b" | sed -n 's/^recall: //p')"
  ch="$(memexp_score "$c" | sed -n 's/^recall: //p')"
  echo
  echo "RECOMMENDATION:"
  if [ "${ch%%/*}" -ge "${bh%%/*}" ]; then
    echo "  the candidate compressor kept recall at least as good ($ch vs baseline $bh)."
    echo "  If it is also cheaper/less quota-dependent, consider switching — MANUALLY,"
    echo "  by editing ~/.claude-mem/settings.json yourself. This tool will not do it."
  else
    echo "  the candidate LOST recall ($ch vs baseline $bh) — do NOT switch."
  fi
}

memexp_report() {
  echo "== claude-mem cost-optimization experiment (P3.15) =="
  echo
  echo "current compressor configuration (secrets redacted):"
  memexp_baseline | sed 's/^/  /'
  echo
  echo "candidate directions to evaluate (each is opt-in, none are enabled here):"
  echo "  A. the upstream-recommended economical model for the current provider"
  echo "  B. a LiteLLM-style gateway in front of the compressor"
  echo "  C. a small local model behind that gateway (only if you already run one;"
  echo "     never a new GPU requirement, never a paid API)"
  echo
  echo "to evaluate a candidate:"
  echo "  1. seed claude-mem with:            agent memexp facts"
  echo "  2. ask each of:                     agent memexp queries"
  echo "  3. save the answers, then:          agent memexp compare <baseline> <candidate>"
  echo
  echo "nothing about your claude-mem setup has been changed."
}
