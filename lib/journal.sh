#!/usr/bin/env bash
# P2.5: durable run journal. JSONL + JSON files under lib/state_paths.sh's
# state dir (never inside the target project). Every write goes through
# lib/json-tools.mjs's atomic temp-file-then-rename helpers, so a reader
# never observes a partially-written file. Sourced by bin/agent. Must not be
# executed directly.
set -euo pipefail

_JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_journal_node() { node "$_JOURNAL_LIB_DIR/json-tools.mjs" "$@"; }

# journal_task_summary <task-text> [max_chars]
# One-line, truncated preview for run.json — the full task text lives only
# in the run dir's own task.txt (mode 600), not duplicated across files
# (P2 spec: "evite cópias redundantes" of potentially sensitive task text).
journal_task_summary() {
  local task="$1" max="${2:-200}"
  local oneline
  oneline="$(printf '%s' "$task" | tr '\n\r\t' '   ' | sed -E 's/ +/ /g')"
  if [ "${#oneline}" -gt "$max" ]; then
    printf '%s...\n' "${oneline:0:$max}"
  else
    printf '%s\n' "$oneline"
  fi
}

# journal_run_create <workspace> <run_id> <task-text> <base_git_head> <dirty: true|false>
# Creates the run directory (mode 700), writes task.txt (mode 600) and the
# initial run.json (state CREATED). Prints the run dir path on stdout.
journal_run_create() {
  local workspace="$1" run_id="$2" task="$3" base_head="$4" dirty="$5"
  local run_dir project_id
  project_id="$(state_project_id "$workspace")"
  run_dir="$(state_run_dir "$workspace" "$run_id")"
  mkdir -p "$run_dir"
  chmod 700 "$run_dir" 2>/dev/null || true

  printf '%s' "$task" > "$run_dir/task.txt"
  chmod 600 "$run_dir/task.txt" 2>/dev/null || true

  local summary
  summary="$(journal_task_summary "$task")"

  _journal_node run-create "$run_dir/run.json" \
    "run_id=$run_id" \
    "project=$project_id" \
    "workspace=$workspace" \
    "task_summary=$summary" \
    "state=CREATED" \
    "base_git_head=$base_head" \
    "current_git_head=$base_head" \
    "dirty_at_start=$dirty"
  chmod 600 "$run_dir/run.json" 2>/dev/null || true

  : > "$run_dir/events.jsonl"
  chmod 600 "$run_dir/events.jsonl" 2>/dev/null || true

  printf '%s\n' "$run_dir"
}

journal_run_json() { printf '%s/run.json\n' "$1"; }
journal_events_path() { printf '%s/events.jsonl\n' "$1"; }

journal_run_get_field() {
  local run_dir="$1" field="$2"
  node "$_JOURNAL_LIB_DIR/json-tools.mjs" get-field "$field" < "$(journal_run_json "$run_dir")"
}

journal_run_get_state() { journal_run_get_field "$1" state; }

# journal_run_transition <run_dir> <new_state> [extra key=value ...]
# Validates the transition against lib/run_lifecycle.sh before writing.
# Fails loudly (never silently) on an invalid transition — a bug in our own
# orchestration code should surface, not be swallowed into a wrong journal.
journal_run_transition() {
  local run_dir="$1" new_state="$2"; shift 2
  local current
  current="$(journal_run_get_state "$run_dir")"
  if ! run_state_can_transition "$current" "$new_state"; then
    echo "journal: invalid state transition $current -> $new_state ($run_dir)" >&2
    return 1
  fi
  _journal_node run-update "$(journal_run_json "$run_dir")" "state=$new_state" "$@"
  journal_event_emit "$run_dir" "run.state_changed" "from=$current" "to=$new_state"
}

# journal_run_update <run_dir> key=value ...
# Field updates that are NOT a state transition (e.g. risk, correction_round,
# current_git_head, last_completed_phase).
journal_run_update() {
  local run_dir="$1"; shift
  _journal_node run-update "$(journal_run_json "$run_dir")" "$@"
}

# A run's own run_id never changes after creation, so cache it per run_dir
# instead of spawning a node process to re-read run.json for every single
# event — one run can easily emit a dozen+ events, and each `node` startup
# has real overhead (P2 principle: stay economical, not just in tokens).
declare -gA _JOURNAL_RUN_ID_CACHE 2>/dev/null || true
_journal_cached_run_id() {
  local run_dir="$1"
  if [ -z "${_JOURNAL_RUN_ID_CACHE[$run_dir]:-}" ]; then
    _JOURNAL_RUN_ID_CACHE["$run_dir"]="$(journal_run_get_field "$run_dir" run_id)"
  fi
  printf '%s' "${_JOURNAL_RUN_ID_CACHE[$run_dir]}"
}

# journal_event_emit <run_dir> <event_name> [key=value ...]
# Structured operational facts only (P2.6) — never hidden model reasoning,
# never a full payload when a size/count metadata field will do.
journal_event_emit() {
  local run_dir="$1" event_name="$2"; shift 2
  _journal_node append-event "$(journal_events_path "$run_dir")" "$event_name" "run_id=$(_journal_cached_run_id "$run_dir")" "$@"
}
