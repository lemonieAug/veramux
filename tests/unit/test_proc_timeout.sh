#!/usr/bin/env bash
# P2.8/P2.16: the timeout/cancellation wrapper around a `dsh`-shaped call.
# Uses short (1-2s) deadlines so this stays fast; no LLM/dsh involved —
# plain bash commands stand in for the wrapped process.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/proc_timeout.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- normal completion within the deadline: passes through the real exit
# code and captures output ---
run_dir1="$TMP/run1"; mkdir -p "$run_dir1"
out1="$TMP/out1.txt"
proc_call_with_timeout "$run_dir1" 5 2 "$out1" -- bash -c 'echo hello-world'
code1=$?
assert_eq "0" "$code1" "a command finishing within the deadline returns its own exit code"
assert_contains "$(cat "$out1")" "hello-world" "stdout is captured to the out file"
assert_exit_code "0" "PID tracking is cleared after the call completes" bash -c "[ ! -f '$(proc_track_path "$run_dir1")' ]"

# a command that fails on its own passes that failure through unchanged
run_dir1b="$TMP/run1b"; mkdir -p "$run_dir1b"
proc_call_with_timeout "$run_dir1b" 5 2 "$TMP/out1b.txt" -- bash -c 'exit 3'
assert_eq "3" "$?" "a command's own nonzero exit is passed through untouched"

# --- exceeding the deadline: killed, reported as 124, never lets the
# command finish and produce its "success" output ---
run_dir2="$TMP/run2"; mkdir -p "$run_dir2"
out2="$TMP/out2.txt"
start_ts=$(date +%s)
proc_call_with_timeout "$run_dir2" 1 1 "$out2" -- bash -c 'sleep 6; echo finished-normally'
code2=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
assert_eq "124" "$code2" "exceeding the deadline reports our fixed timeout convention (124)"
assert_eq "1" "$([ "$elapsed" -le 4 ] && echo 1 || echo 0)" "the process was actually killed, not left to run the full 6s sleep (elapsed=${elapsed}s)"
assert_not_contains "$(cat "$out2")" "finished-normally" "a 0-exit-after-kill can never be mistaken for a real success: the command never got that far"

# --- external cancellation: proc_cancel_request signals an in-flight call
# before its own deadline, and the marker survives for the caller to check
# (the authoritative signal — never inferred from the child's exit code
# alone, since SIGTERM can make a child exit 0 on its own graceful path) ---
run_dir3="$TMP/run3"; mkdir -p "$run_dir3"
out3="$TMP/out3.txt"
( proc_call_with_timeout "$run_dir3" 30 3 "$out3" -- bash -c 'sleep 20; echo finished-normally' ) &
bgpid=$!

found_tracking=0
for _ in $(seq 1 50); do
  if [ -f "$(proc_track_path "$run_dir3")" ]; then found_tracking=1; break; fi
  sleep 0.1
done
assert_eq "1" "$found_tracking" "the in-flight process is tracked (active.pid appears) before we try to cancel it"

cancel_start=$(date +%s)
assert_exit_code "0" "proc_cancel_request finds and signals the tracked process" proc_cancel_request "$run_dir3"
wait "$bgpid" 2>/dev/null
cancel_elapsed=$(( $(date +%s) - cancel_start ))

assert_exit_code "0" "the cancel marker is set" proc_cancel_requested "$run_dir3"
assert_eq "1" "$([ "$cancel_elapsed" -le 10 ] && echo 1 || echo 0)" "cancellation actually stopped the process well before its 30s/20s deadlines (elapsed=${cancel_elapsed}s)"
assert_not_contains "$(cat "$out3")" "finished-normally" "the cancelled process never reached its own completion output"

proc_cancel_clear_marker "$run_dir3"
assert_exit_code "1" "clearing the marker removes it" proc_cancel_requested "$run_dir3"

# --- cancelling a run with nothing in flight is reported, not an error ---
run_dir4="$TMP/run4"; mkdir -p "$run_dir4"
assert_exit_code "1" "cancelling with nothing tracked returns 1 (nothing to signal)" proc_cancel_request "$run_dir4"
assert_exit_code "0" "the marker is still written even when nothing was live to signal" proc_cancel_requested "$run_dir4"

report_and_exit
