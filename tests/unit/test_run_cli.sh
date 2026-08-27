#!/usr/bin/env bash
# P2.16: operational CLI commands (status/runs/show/logs/cancel/unlock).
# No LLM calls — only journal/lock state.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/journal.sh"
source "$ROOT_DIR/lib/failures.sh"
source "$ROOT_DIR/lib/proc_timeout.sh"
source "$ROOT_DIR/lib/workspace_lock.sh"
source "$ROOT_DIR/lib/run_cli.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

WORKSPACE="$TMP/repo"; mkdir -p "$WORKSPACE"; git -C "$WORKSPACE" init -q

# --- no runs yet ---
assert_contains "$(run_cli_runs "$WORKSPACE")" "no runs recorded" "run_cli_runs reports emptiness clearly, not silently"
assert_contains "$(run_cli_status "$WORKSPACE")" "active run: none" "run_cli_status shows no active run initially"
assert_contains "$(run_cli_status "$WORKSPACE")" "not locked" "run_cli_status shows unlocked initially"

# --- create two runs, one completed, one still in flight ---
run_a="$(run_id_generate)"; sleep 1
run_dir_a="$(journal_run_create "$WORKSPACE" "$run_a" "first task" "head1" "false")"
journal_run_transition "$run_dir_a" CONTEXT
journal_run_transition "$run_dir_a" IMPLEMENTING
journal_run_transition "$run_dir_a" VALIDATING
journal_run_transition "$run_dir_a" COMPLETED

run_b="$(run_id_generate)"
run_dir_b="$(journal_run_create "$WORKSPACE" "$run_b" "second task, still running" "head2" "false")"
journal_run_transition "$run_dir_b" CONTEXT
journal_run_update "$run_dir_b" "risk=medium"

# --- run_cli_runs lists both, newest first ---
runs_out="$(run_cli_runs "$WORKSPACE")"
assert_contains "$runs_out" "$run_a" "run_cli_runs lists the completed run"
assert_contains "$runs_out" "$run_b" "run_cli_runs lists the in-flight run"
assert_contains "$runs_out" "COMPLETED" "run_cli_runs shows each run's state"
first_line="$(printf '%s\n' "$runs_out" | head -1)"
assert_contains "$first_line" "$run_b" "run_cli_runs sorts newest-first"

# --- run_cli_show: sanitized, no raw task text file dumped ---
show_out="$(run_cli_show "$run_b")"
assert_contains "$show_out" "second task, still running" "run_cli_show includes the task summary"
assert_contains "$show_out" "state: CONTEXT" "run_cli_show includes the current state"
assert_contains "$show_out" "risk: medium" "run_cli_show includes risk"
assert_contains "$show_out" "head2" "run_cli_show includes git head info"

code=0
run_cli_show "nonexistent-run-id" >/tmp/show_missing.out 2>&1 || code=$?
assert_eq "1" "$code" "run_cli_show on an unknown run id fails clearly"

# --- run_cli_logs ---
journal_event_emit "$run_dir_b" "lead.started" "provider=claude-code"
logs_out="$(run_cli_logs "$run_b")"
assert_contains "$logs_out" "run.state_changed" "run_cli_logs shows recorded events"
assert_contains "$logs_out" "lead.started" "run_cli_logs shows an explicitly emitted event"
json_logs="$(run_cli_logs "$run_b" --json)"
assert_contains "$json_logs" '"schema_version":1' "run_cli_logs --json prints raw structured lines"

# --- workspace lock reflected in status ---
workspace_lock_acquire "$WORKSPACE" "$run_b"
status_out="$(run_cli_status "$WORKSPACE")"
assert_contains "$status_out" "locked by run $run_b" "run_cli_status reflects an active lock"
assert_contains "$status_out" "active run: $run_b" "run_cli_status identifies the active run via the lock"

# --- run_cli_cancel: marks CANCELLED, cannot re-cancel a terminal run ---
cancel_out="$(run_cli_cancel "$run_b")"
assert_contains "$cancel_out" "CANCELLED" "run_cli_cancel reports the resulting state"
assert_eq "CANCELLED" "$(journal_run_get_state "$run_dir_b")" "the journal actually records CANCELLED"

already_out="$(run_cli_cancel "$run_a")"
assert_contains "$already_out" "already in a terminal state" "cancelling an already-COMPLETED run is a no-op, reported as such"

# --- unlock (the lock from run_b, acquired above, is still held) ---
unlock_out="$(run_cli_unlock "$WORKSPACE")"
assert_contains "$unlock_out" "removing lock" "run_cli_unlock reports removing the held lock"
assert_exit_code "1" "workspace is unlocked after run_cli_unlock" workspace_lock_is_locked "$WORKSPACE"

report_and_exit
