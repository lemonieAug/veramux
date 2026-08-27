#!/usr/bin/env bash
# P2.12: workspace locking (mkdir-atomic), stale-lock detection, force unlock.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/workspace_lock.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

WORKSPACE="$TMP/repo"; mkdir -p "$WORKSPACE"; git -C "$WORKSPACE" init -q

# --- basic acquire/release ---
assert_exit_code "1" "workspace starts unlocked" workspace_lock_is_locked "$WORKSPACE"
assert_exit_code "0" "first acquire succeeds" workspace_lock_acquire "$WORKSPACE" "run-A"
assert_exit_code "0" "lock is now held" workspace_lock_is_locked "$WORKSPACE"
assert_contains "$(workspace_lock_info "$WORKSPACE")" "run-A" "lock info records the owning run"

# a second run cannot acquire the same workspace while run-A holds it (this
# process is alive, so it's never considered stale)
code=0
workspace_lock_acquire "$WORKSPACE" "run-B" 2>/tmp/lock_conflict.out || code=$?
assert_eq "1" "$code" "a second run is blocked while the first (live) run holds the lock"
assert_contains "$(cat /tmp/lock_conflict.out)" "already holds this workspace" "the conflict is reported, not silently swallowed"

# releasing with the WRONG run id must not release someone else's lock
workspace_lock_release "$WORKSPACE" "run-B"
assert_exit_code "0" "lock is still held after a non-owner release attempt" workspace_lock_is_locked "$WORKSPACE"

# releasing with the correct run id works
workspace_lock_release "$WORKSPACE" "run-A"
assert_exit_code "1" "lock is released by its actual owner" workspace_lock_is_locked "$WORKSPACE"

# --- stale lock: same host, dead pid -> reclaimed automatically ---
workspace_lock_acquire "$WORKSPACE" "run-C"
lockdir="$(workspace_lock_dir "$WORKSPACE")"
# fabricate a stale entry: a pid that (almost certainly) doesn't exist
printf 'run-C\t999999\t%s\t2020-01-01T00:00:00Z\n' "$(hostname 2>/dev/null || echo unknown)" > "$lockdir/info"
assert_exit_code "0" "same-host, dead-pid lock is detected as stale" workspace_lock_is_stale "$WORKSPACE"
assert_exit_code "0" "acquiring over a stale lock succeeds (auto-reclaimed)" workspace_lock_acquire "$WORKSPACE" "run-D"
assert_contains "$(workspace_lock_info "$WORKSPACE")" "run-D" "the reclaimed lock now belongs to the new run"
workspace_lock_release "$WORKSPACE" "run-D"

# --- cross-host lock: never auto-broken, even with an unfamiliar pid ---
workspace_lock_acquire "$WORKSPACE" "run-E"
lockdir="$(workspace_lock_dir "$WORKSPACE")"
printf 'run-E\t999999\tsome-other-host\t2020-01-01T00:00:00Z\n' > "$lockdir/info"
assert_exit_code "1" "a different hostname's lock is NEVER auto-considered stale (can't verify a foreign PID namespace)" workspace_lock_is_stale "$WORKSPACE"
code=0
workspace_lock_acquire "$WORKSPACE" "run-F" 2>/dev/null || code=$?
assert_eq "1" "$code" "acquire refuses to break a cross-host lock automatically"
assert_contains "$(workspace_lock_info "$WORKSPACE")" "some-other-host" "the cross-host lock is left untouched"

# --- explicit force-unlock always works, regardless of staleness ---
out="$(workspace_lock_force_unlock "$WORKSPACE")"
assert_contains "$out" "removing lock" "force-unlock reports what it did"
assert_exit_code "1" "force-unlock always clears the lock" workspace_lock_is_locked "$WORKSPACE"
out2="$(workspace_lock_force_unlock "$WORKSPACE")"
assert_contains "$out2" "no lock held" "force-unlock on an already-unlocked workspace says so, doesn't error"

report_and_exit
