#!/usr/bin/env bash
# Best-effort P1 benchmark (P1.16): summarizes ONE `agent` run's context and
# review footprint from its run_dir artifacts (the "run artifacts: <dir>"
# line every run prints).
#
# Honest limitation, not a bug: DSH's subagent contract never exposes a
# child's tool-call trace to the parent (see docs/upstream-findings.md), so
# this cannot report literal "files Claude read" or token counts inside its
# session — only what our own orchestrator controls: how big and how
# composed the context package we built was, the risk classification, and
# how many times the reviewer/lead were actually invoked. That is enough to
# demonstrate the P0-vs-P1 point (context assembled once, capped, and
# reused, instead of an unconstrained Claude read-everything loop) without
# fabricating numbers we cannot actually observe.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/benchmark.sh <run_dir>

<run_dir> is the directory an `agent` invocation printed as
"run artifacts: <run_dir>". Prints a one-line JSON summary to stdout.
EOF
}

if [ $# -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  usage
  exit "$([ $# -lt 1 ] && echo 1 || echo 0)"
fi

RUN_DIR="$1"
if [ ! -d "$RUN_DIR" ]; then
  echo "error: not a directory: $RUN_DIR" >&2
  exit 1
fi

bool_json() { [ "$1" -eq 1 ] && echo true || echo false; }

context_chars=0
has_memory=0
has_graph=0
has_grep_fallback=0
has_external=0
if [ -f "$RUN_DIR/context.md" ]; then
  context_chars=$(wc -c < "$RUN_DIR/context.md" | tr -d '[:space:]')
  grep -q '^## Memory' "$RUN_DIR/context.md" && has_memory=1
  grep -q '^## Architecture (knowledge graph)' "$RUN_DIR/context.md" && has_graph=1
  grep -q '^## Possibly relevant source' "$RUN_DIR/context.md" && has_grep_fallback=1
  grep -q '^## External research' "$RUN_DIR/context.md" && has_external=1
fi

risk_tier="null"
if [ -f "$RUN_DIR/risk.txt" ]; then
  risk_tier="\"$(head -1 "$RUN_DIR/risk.txt" | awk '{print tolower($1)}')\""
fi

# `grep -c`/`wc -l` already print a correct "0" on no matches; the `|| true`
# only neutralizes their nonzero exit status for `set -e` — the count itself
# is never affected by it.
review_rounds=$(find "$RUN_DIR" -maxdepth 1 -name 'review-[0-9]*.json' 2>/dev/null | grep -vc -- '-retry' || true)
review_retries=$(find "$RUN_DIR" -maxdepth 1 -name 'review-raw-*-retry.json' 2>/dev/null | wc -l | tr -d '[:space:]' || true)
correction_rounds=$(find "$RUN_DIR" -maxdepth 1 -name 'lead-correction-message-*.txt' 2>/dev/null | wc -l | tr -d '[:space:]' || true)

validation_summary="null"
if [ -f "$RUN_DIR/validation.json" ]; then
  validation_summary="\"$(node "$(dirname "${BASH_SOURCE[0]}")/../lib/json-tools.mjs" validation-summary "$RUN_DIR/validation.json" 2>/dev/null | tr -d '\n' | sed 's/"/\\"/g')\""
fi

cat <<EOF
{"run_dir":"$RUN_DIR","context_package_chars":$context_chars,"context_included":{"memory":$(bool_json "$has_memory"),"graph":$(bool_json "$has_graph"),"grep_fallback":$(bool_json "$has_grep_fallback"),"external":$(bool_json "$has_external")},"risk_tier":$risk_tier,"reviewer_invocations":$review_rounds,"reviewer_json_retries":$review_retries,"correction_rounds":$correction_rounds,"final_validation_summary":$validation_summary}
EOF
