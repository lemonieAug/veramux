#!/usr/bin/env bash
# P2.16: operational CLI commands (status/runs/show/logs/cancel/cleanup/
# unlock). None of these ever call an LLM — they only read/write the run
# journal and lock state. `resume` lives in lib/resume.sh (needs git-safety
# helpers this file doesn't). Sourced by bin/agent. Must not be executed
# directly.
set -euo pipefail

_RUN_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run_cli_find_run_dir <run_id>
# run ids are globally unique (timestamp+random, see run_id_generate), so a
# scan across every project's runs dir is enough — prints the match's path,
# or nothing.
run_cli_find_run_dir() {
  local run_id="$1" runs_root
  runs_root="$(state_runs_root_dir)"
  [ -d "$runs_root" ] || return 0
  find "$runs_root" -mindepth 2 -maxdepth 2 -type d -name "$run_id" 2>/dev/null | head -1
}

# run_cli_list_run_dirs [workspace]
# All run dirs, optionally filtered to one workspace's project id, newest
# first (run ids sort lexicographically by time).
run_cli_list_run_dirs() {
  local workspace="${1:-}" runs_root project_dir
  runs_root="$(state_runs_root_dir)"
  [ -d "$runs_root" ] || return 0
  if [ -n "$workspace" ]; then
    project_dir="$(state_project_runs_dir "$workspace")"
    [ -d "$project_dir" ] || return 0
    find "$project_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r
  else
    find "$runs_root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort -r
  fi
}

_run_cli_field() {
  local run_dir="$1" field="$2"
  node "$_RUN_CLI_LIB_DIR/json-tools.mjs" get-field "$field" < "$run_dir/run.json" 2>/dev/null
}

# run_cli_status <workspace>
# No LLM calls. Project, active run (if the lock is held), current phase,
# lock status, most recent run, provider presence.
run_cli_status() {
  local workspace="$1" locked="not locked" active_run=""
  echo "project: $(state_project_id "$workspace") ($workspace)"

  if workspace_lock_is_locked "$workspace"; then
    local info run_id
    info="$(workspace_lock_info "$workspace")"
    run_id="$(printf '%s' "$info" | cut -f1)"
    locked="locked by run $run_id (pid $(printf '%s' "$info" | cut -f2), host $(printf '%s' "$info" | cut -f3))"
    active_run="$run_id"
  fi
  echo "lock: $locked"

  if [ -n "$active_run" ]; then
    local run_dir
    run_dir="$(run_cli_find_run_dir "$active_run")"
    if [ -n "$run_dir" ]; then
      echo "active run: $active_run"
      echo "  state: $(_run_cli_field "$run_dir" state)"
      echo "  risk: $(_run_cli_field "$run_dir" risk)"
      echo "  started_at: $(_run_cli_field "$run_dir" started_at)"
    fi
  else
    echo "active run: none"
  fi

  local last_dir
  last_dir="$(run_cli_list_run_dirs "$workspace" | head -1)"
  if [ -n "$last_dir" ]; then
    echo "last run: $(basename "$last_dir") — state: $(_run_cli_field "$last_dir" state), updated_at: $(_run_cli_field "$last_dir" updated_at)"
  else
    echo "last run: none"
  fi

  echo "providers:"
  env_has_cmd dsh && echo "  dsh: present" || echo "  dsh: NOT FOUND"
  local relay_env_file
  relay_env_file="$(env_dsh_home)/.env"
  if env_orchestrator_deepseek_configured "$relay_env_file"; then
    echo "  relay primary: DeepSeek configured"
  else
    echo "  relay primary: DeepSeek NOT configured"
  fi
  if env_orchestrator_openai_configured "$relay_env_file"; then
    echo "  relay fallback: OpenAI configured"
  else
    echo "  relay fallback: OpenAI not configured"
  fi
  env_has_cmd claude && echo "  claude CLI: present" || echo "  claude CLI: not on PATH (not required)"
  env_has_cmd codex && echo "  codex CLI: present" || echo "  codex CLI: not on PATH (not required)"
}

# run_cli_runs <workspace>
# run_id, date, project, state, risk, duration — never prompts/task text.
run_cli_runs() {
  local workspace="$1" dir run_id state risk started updated
  local any=0
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    any=1
    run_id="$(basename "$dir")"
    state="$(_run_cli_field "$dir" state)"
    risk="$(_run_cli_field "$dir" risk)"
    started="$(_run_cli_field "$dir" started_at)"
    updated="$(_run_cli_field "$dir" updated_at)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$run_id" "$state" "${risk:-?}" "$started" "$updated"
  done < <(run_cli_list_run_dirs "$workspace")
  [ "$any" -eq 1 ] || echo "no runs recorded for this project yet"
}

# run_cli_show <run_id>
# Sanitized summary: task summary (never the raw multi-KB task text file),
# state, phase, validation/review results if present, failure if any.
run_cli_show() {
  local run_id="$1" run_dir
  run_dir="$(run_cli_find_run_dir "$run_id")"
  if [ -z "$run_dir" ]; then
    echo "error: no such run: $run_id" >&2
    return 1
  fi
  echo "run: $run_id"
  echo "task_summary: $(_run_cli_field "$run_dir" task_summary)"
  echo "state: $(_run_cli_field "$run_dir" state)"
  echo "risk: $(_run_cli_field "$run_dir" risk)"
  echo "last_completed_phase: $(_run_cli_field "$run_dir" last_completed_phase)"
  echo "correction_round: $(_run_cli_field "$run_dir" correction_round)"
  echo "started_at: $(_run_cli_field "$run_dir" started_at)"
  echo "updated_at: $(_run_cli_field "$run_dir" updated_at)"
  echo "base_git_head: $(_run_cli_field "$run_dir" base_git_head)"
  echo "current_git_head: $(_run_cli_field "$run_dir" current_git_head)"
  echo "dirty_at_start: $(_run_cli_field "$run_dir" dirty_at_start)"
  echo "primary_provider: $(_run_cli_field "$run_dir" primary_provider)"
  echo "fallback_triggered: $(_run_cli_field "$run_dir" fallback_triggered)"
  echo "last_relay_provider: $(_run_cli_field "$run_dir" last_relay_provider)"
  if [ -f "$run_dir/project-profile.json" ]; then
    echo "project profile (P2.3): $(node -e '
      const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
      const j = (a) => (a && a.length ? a.join("/") : "-")
      process.stdout.write("languages=" + j(p.languages) + " pm=" + (p.package_manager || "-") +
        " frameworks=" + j(p.frameworks) + " validation=" + Object.keys(p.validation || {}).join(",") )
    ' "$run_dir/project-profile.json" 2>/dev/null)"
  fi
  if [ -f "$run_dir/validation.json" ]; then
    echo "validation: $(node "$_RUN_CLI_LIB_DIR/json-tools.mjs" validation-summary "$run_dir/validation.json" 2>/dev/null)"
  fi
  if [ -f "$run_dir/review.json" ]; then
    echo "review verdict: $(node "$_RUN_CLI_LIB_DIR/json-tools.mjs" review-verdict "$run_dir/review.json" 2>/dev/null)"
  fi
  if [ -f "$run_dir/final.json" ]; then
    echo "final:"
    cat "$run_dir/final.json"
    echo
  fi
}

# run_cli_logs <run_id> [--json]
run_cli_logs() {
  local run_id="$1" fmt="${2:-}" run_dir
  run_dir="$(run_cli_find_run_dir "$run_id")"
  if [ -z "$run_dir" ]; then
    echo "error: no such run: $run_id" >&2
    return 1
  fi
  if [ ! -f "$run_dir/events.jsonl" ]; then
    echo "no events recorded for this run"
    return 0
  fi
  if [ "$fmt" = "--json" ]; then
    cat "$run_dir/events.jsonl"
  else
    local line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      node "$_RUN_CLI_LIB_DIR/json-tools.mjs" get-field timestamp <<< "$line" | tr -d '\n'
      printf ' '
      node "$_RUN_CLI_LIB_DIR/json-tools.mjs" get-field event <<< "$line"
    done < "$run_dir/events.jsonl"
  fi
}

# run_cli_cancel <run_id>
# Marks the cancel request (so any in-flight dsh call is signalled AND the
# outcome is reported as CANCELLED regardless of the child's own exit
# code), and transitions the journal if it's still in a non-terminal state.
run_cli_cancel() {
  local run_id="$1" run_dir state
  run_dir="$(run_cli_find_run_dir "$run_id")"
  if [ -z "$run_dir" ]; then
    echo "error: no such run: $run_id" >&2
    return 1
  fi
  state="$(_run_cli_field "$run_dir" state)"
  if run_state_is_terminal "$state"; then
    echo "run $run_id is already in a terminal state ($state) — nothing to cancel"
    return 0
  fi
  if proc_cancel_request "$run_dir"; then
    echo "cancel requested — signalled the in-flight process for run $run_id"
  else
    echo "cancel requested — no in-flight process found (run may be between steps); it will stop at its next checkpoint"
  fi
  if run_state_can_transition "$state" CANCELLED; then
    journal_run_transition "$run_dir" CANCELLED
  fi
  echo "run $run_id: CANCELLED"
}

# run_cli_unlock <workspace>
run_cli_unlock() { workspace_lock_force_unlock "$1"; }
