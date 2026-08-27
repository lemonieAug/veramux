#!/usr/bin/env bash
# P2.13: git-state capture/comparison for safe resume. Never performs a
# destructive recovery action itself (no reset --hard, no clean -fd, no
# checkout --) — it only detects and reports; lib/resume.sh decides what to
# do with the report. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_GIT_SAFETY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git_safety_current_head() {
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "no-commits"
}

# git_safety_snapshot <workspace> <run_dir>
# Records what the run started from: HEAD and full `git status --porcelain`
# output (pre-existing dirty files) — so a later resume can tell "the user's
# own prior changes" apart from "changes this run made" where possible, per
# spec, without needing a second copy of the diff itself.
git_safety_snapshot() {
  local workspace="$1" run_dir="$2"
  project_git_status "$workspace" > "$run_dir/git-status-start.txt" 2>/dev/null || : > "$run_dir/git-status-start.txt"
}

# git_safety_head_conflict <run_dir> <workspace>
# True when the branch HEAD has moved since this run started (a commit,
# checkout, rebase, or pull happened outside the agent) — the one
# unambiguous "don't touch this automatically" signal. Never a false
# negative: an unset/unreadable recorded head is treated as "can't verify",
# not as "no conflict".
git_safety_head_conflict() {
  local run_dir="$1" workspace="$2" recorded current
  recorded="$(journal_run_get_field "$run_dir" base_git_head)"
  [ -z "$recorded" ] || [ "$recorded" = "null" ] && return 0
  current="$(git_safety_current_head "$workspace")"
  [ "$recorded" != "$current" ]
}

# journal_call_in_flight <run_dir> <event_prefix>
# True when the run's own events.jsonl shows "<prefix>.started" as its most
# recent occurrence of that call with no matching "<prefix>.completed" or
# "<prefix>.failed" AFTER it — i.e. that specific call was genuinely
# interrupted mid-flight, not merely "about to start" or "already finished".
# This is what actually distinguishes "Claude died mid-edit, workspace may
# be half-written" (P2 spec Scenario E) from "the phase transition happened
# but the call itself never started" (safe to just (re)try it).
journal_call_in_flight() {
  local run_dir="$1" prefix="$2" events="$run_dir/events.jsonl"
  [ -f "$events" ] || { echo "false"; return 0; }
  local last_started_line
  last_started_line="$(grep -n "\"event\":\"${prefix}\.started\"" "$events" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -z "$last_started_line" ]; then
    echo "false"
    return 0
  fi
  local after
  after="$(tail -n "+$((last_started_line + 1))" "$events" 2>/dev/null)"
  if printf '%s' "$after" | grep -qE "\"event\":\"${prefix}\.(completed|failed)\""; then
    echo "false"
  else
    echo "true"
  fi
}
