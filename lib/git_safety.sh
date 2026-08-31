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

# git_safety_implementation_baseline_create <workspace> <run_dir>
# Copies the Git-visible file set to run-owned state before Context starts.
# This preserves a dirty user workspace while giving the reviewer a temporal
# baseline for changes produced by the current run. Ignored artifacts are
# deliberately outside the review surface, as they are outside git diff too.
git_safety_implementation_baseline_create() {
  local workspace="$1" run_dir="$2" baseline manifest path
  baseline="$run_dir/workspace-baseline"
  manifest="$run_dir/workspace-baseline-files.txt"
  mkdir -p "$baseline"
  : > "$manifest"
  project_is_git_repo "$workspace" >/dev/null 2>&1 || return 0
  while IFS= read -r -d '' path; do
    [ -f "$workspace/$path" ] || continue
    printf '%s\n' "$path" >> "$manifest"
    mkdir -p "$baseline/$(dirname "$path")"
    cp -p -- "$workspace/$path" "$baseline/$path"
  done < <(git -C "$workspace" ls-files -co --exclude-standard -z)
}

# git_safety_implementation_changed_files <workspace> <run_dir>
# Reports only paths changed after the run baseline, not pre-existing dirty
# files. New files are included; removed files remain reportable.
git_safety_implementation_changed_files() {
  local workspace="$1" run_dir="$2" baseline="$run_dir/workspace-baseline"
  local manifest="$run_dir/workspace-baseline-files.txt" path
  declare -A seen=()
  if [ -f "$manifest" ]; then
    while IFS= read -r path; do
      seen["$path"]=1
    done < "$manifest"
  fi
  while IFS= read -r -d '' path; do seen["$path"]=1; done < <(git -C "$workspace" ls-files -co --exclude-standard -z)
  for path in "${!seen[@]}"; do
    if [ -f "$baseline/$path" ] && [ -f "$workspace/$path" ] && cmp -s -- "$baseline/$path" "$workspace/$path"; then
      continue
    fi
    printf '%s\n' "$path"
  done | sort
}

# git_safety_implementation_diff <workspace> <run_dir>
# Emits an untruncated per-file diff from the run-owned baseline. The output
# is deliberately independent of the repository index, which means existing
# staged/unstaged user edits never enter the reviewer payload.
git_safety_implementation_diff() {
  local workspace="$1" run_dir="$2" baseline="$run_dir/workspace-baseline" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    git diff --no-index --no-ext-diff -- "$baseline/$path" "$workspace/$path" || true
  done < <(git_safety_implementation_changed_files "$workspace" "$run_dir")
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
