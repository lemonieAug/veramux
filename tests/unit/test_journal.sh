#!/usr/bin/env bash
# P2.4/P2.5: state paths (project-id, dirs) + the durable run journal
# (run.json, events.jsonl, atomic writes, state-transition validation).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/journal.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

WORKSPACE="$TMP/repo"
mkdir -p "$WORKSPACE"
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" -c user.email=t@t.com -c user.name=t commit -q --allow-empty -m init

# --- state paths ---
assert_eq "$TMP/state" "$(state_root_dir)" "AGENT_STATE_HOME override wins"
pid1="$(state_project_id "$WORKSPACE")"
pid2="$(state_project_id "$WORKSPACE")"
assert_eq "$pid1" "$pid2" "project id is stable across calls"

other_ws="$TMP/other-repo"; mkdir -p "$other_ws"; git -C "$other_ws" init -q
pid3="$(state_project_id "$other_ws")"
[ "$pid1" != "$pid3" ] && PASS_COUNT=$((PASS_COUNT + 1)) || { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: different repos should get different project ids" >&2; }

subdir="$WORKSPACE/src"; mkdir -p "$subdir"
assert_eq "$pid1" "$(state_project_id "$subdir")" "a subdirectory of a git repo maps to the same project id as the repo root"

# --- journal_task_summary ---
long_task="$(printf 'x%.0s' $(seq 1 300))"
summary="$(journal_task_summary "$long_task")"
assert_eq "1" "$( [ "${#summary}" -le 210 ] && echo 1 || echo 0 )" "task summary is truncated, not the full 300 chars"
assert_contains "$summary" "..." "truncated summary is marked with an ellipsis"
multiline_task="line one
line two"
oneline_summary="$(journal_task_summary "$multiline_task")"
if [[ "$oneline_summary" == *$'\n'* ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: task summary collapses newlines to spaces: got [$oneline_summary]" >&2
else
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# --- run creation ---
run_id="$(run_id_generate)"
run_dir="$(journal_run_create "$WORKSPACE" "$run_id" "fix the thing" "abc123" "false")"
assert_eq "1" "$( [ -d "$run_dir" ] && echo 1 || echo 0 )" "run dir was created"
assert_eq "1" "$( [ -f "$run_dir/run.json" ] && echo 1 || echo 0 )" "run.json was created"
assert_eq "1" "$( [ -f "$run_dir/task.txt" ] && echo 1 || echo 0 )" "task.txt was created"
assert_eq "fix the thing" "$(cat "$run_dir/task.txt")" "task.txt holds the full task text"
assert_eq "CREATED" "$(journal_run_get_state "$run_dir")" "new run starts in CREATED"
assert_eq "$run_id" "$(journal_run_get_field "$run_dir" run_id)" "run.json records its own run_id"
assert_eq "abc123" "$(journal_run_get_field "$run_dir" base_git_head)" "run.json records base_git_head"
assert_eq "abc123" "$(journal_run_get_field "$run_dir" current_git_head)" "current_git_head starts equal to base"
assert_eq "false" "$(journal_run_get_field "$run_dir" dirty_at_start)" "dirty_at_start recorded"
assert_contains "$(cat "$run_dir/run.json")" '"schema_version": 1' "run.json carries schema_version from the start"

# --- run.json is never world-readable (P2 security: state dir contains
# potentially private task text/paths) — only asserted on a filesystem that
# actually enforces POSIX permission bits (NTFS/git-bash's chmod is a
# best-effort no-op, so this is skipped there rather than giving a false
# failure or a false pass).
if command -v stat >/dev/null 2>&1; then
  canary="$(mktemp)"; chmod 000 "$canary" 2>/dev/null
  canary_perms="$(stat -c '%a' "$canary" 2>/dev/null || stat -f '%A' "$canary" 2>/dev/null)"
  rm -f "$canary"
  if [ "$canary_perms" = "000" ]; then
    perms="$(stat -c '%a' "$run_dir/run.json" 2>/dev/null || stat -f '%A' "$run_dir/run.json" 2>/dev/null)"
    other_bit="${perms: -1}"
    if [ $(( other_bit & 4 )) -eq 0 ]; then
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: run.json is not world-readable: perms=$perms" >&2
    fi
  else
    echo "skipping world-readable assertion: this filesystem does not enforce POSIX permission bits (chmod 000 produced $canary_perms)"
  fi
fi

# --- state transitions via the journal ---
journal_run_transition "$run_dir" CONTEXT
assert_eq "CONTEXT" "$(journal_run_get_state "$run_dir")" "transition CREATED -> CONTEXT persisted"

journal_run_transition "$run_dir" IMPLEMENTING
assert_eq "IMPLEMENTING" "$(journal_run_get_state "$run_dir")" "transition CONTEXT -> IMPLEMENTING persisted"

# invalid transition is rejected and does not mutate the journal
code=0
journal_run_transition "$run_dir" COMPLETED 2>/tmp/journal_invalid.out || code=$?
assert_eq "1" "$code" "an invalid transition (IMPLEMENTING -> COMPLETED) is rejected"
assert_eq "IMPLEMENTING" "$(journal_run_get_state "$run_dir")" "state is unchanged after a rejected transition"
assert_contains "$(cat /tmp/journal_invalid.out)" "invalid state transition" "the rejection is reported, not silent"

# --- events ---
journal_event_emit "$run_dir" "lead.started" "provider=claude-code"
journal_event_emit "$run_dir" "lead.completed" "provider=claude-code" "duration_ms=1234"
event_count="$(wc -l < "$run_dir/events.jsonl" | tr -d ' ')"
# transitions above also emitted run.state_changed events (2 valid ones)
assert_eq "4" "$event_count" "events.jsonl has one line per emitted event (2 state changes + 2 explicit events)"
assert_contains "$(cat "$run_dir/events.jsonl")" '"event":"lead.completed"' "event name is recorded"
assert_contains "$(cat "$run_dir/events.jsonl")" '"duration_ms":1234' "numeric event fields are coerced to JSON numbers, not strings"
assert_contains "$(cat "$run_dir/events.jsonl")" '"schema_version":1' "every event line carries schema_version"

# --- run_cli_field-style updates (not a transition) ---
journal_run_update "$run_dir" "risk=high" "correction_round=1"
assert_eq "high" "$(journal_run_get_field "$run_dir" risk)" "non-transition field update: risk"
assert_eq "1" "$(journal_run_get_field "$run_dir" correction_round)" "non-transition field update: correction_round"
assert_eq "IMPLEMENTING" "$(journal_run_get_state "$run_dir")" "a plain field update never changes state"

# --- secrets never make it into the journal ---
code=0
node "$ROOT_DIR/lib/json-tools.mjs" run-update "$run_dir/run.json" "api_key=sk-secret" 2>/tmp/journal_secret.out || code=$?
assert_eq "2" "$code" "writing a secret-shaped field to the journal is refused"
assert_not_contains "$(cat "$run_dir/run.json")" "sk-secret" "the refused secret value never reached the journal file"

report_and_exit
