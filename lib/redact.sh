#!/usr/bin/env bash
# Secret/sensitive-file redaction for anything sent to the Codex reviewer
# (P0.10). Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

redact_load_patterns() {
  local safety_file="$1"
  awk '
    /^ignore_patterns:/ { flag=1; next }
    /^[a-zA-Z]/ { flag=0 }
    flag && /^[[:space:]]*-/ { print }
  ' "$safety_file" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/'
}

# Converts our small glob-pattern subset (literal chars + `*`) into one
# anchored extended-regex alternation, matched with awk's POSIX ERE engine.
redact_patterns_to_regex() {
  local -a patterns=("$@")
  local regex="" p esc
  for p in "${patterns[@]}"; do
    [ -z "$p" ] && continue
    esc="$(printf '%s' "$p" | sed -E 's/[[\^$()+{}|]/\\&/g; s/\./[.]/g; s/\*/.*/g')"
    if [ -z "$regex" ]; then regex="^${esc}\$"; else regex="${regex}|^${esc}\$"; fi
  done
  printf '%s' "$regex"
}

# Reads a unified diff on stdin, replaces the content of any hunk touching a
# sensitive path (per policies/safety.yaml) with a placeholder, and prints
# the result. The changed filename is still visible; its content is not.
redact_diff() {
  local safety_file="$1"
  local -a patterns
  mapfile -t patterns < <(redact_load_patterns "$safety_file")
  local regex
  regex="$(redact_patterns_to_regex "${patterns[@]}")"

  awk -v pat="$regex" '
    function basename(p,    n, arr) { n = split(p, arr, "/"); return arr[n] }
    function is_sensitive(p) {
      if (pat == "") return 0
      return (p ~ ("(" pat ")")) || (basename(p) ~ ("(" pat ")"))
    }
    function emit() {
      if (sensitive) {
        printf "diff --git a/%s b/%s\n[REDACTED: sensitive file excluded from review]\n\n", path, path
      } else {
        printf "%s", buf
      }
    }
    BEGIN { path = ""; sensitive = 0; buf = "" }
    /^diff --git a\/.* b\/.*/ {
      if (path != "") emit()
      buf = $0 "\n"
      line = $0
      sub(/^diff --git a\//, "", line)
      sub(/ b\/.*$/, "", line)
      path = line
      sensitive = is_sensitive(path)
      next
    }
    { buf = buf $0 "\n" }
    END { if (path != "") emit() }
  '
}

# Lists changed files considered sensitive, for the "don't send affected
# files we shouldn't" side of context-package construction.
redact_sensitive_paths() {
  local safety_file="$1"
  shift
  local -a patterns
  mapfile -t patterns < <(redact_load_patterns "$safety_file")
  local path p base
  for path in "$@"; do
    base="$(basename "$path")"
    for p in "${patterns[@]}"; do
      if [[ "$path" == $p ]] || [[ "$base" == $p ]]; then
        printf '%s\n' "$path"
        break
      fi
    done
  done
}
