#!/usr/bin/env bash
# P2.12: workspace locking — stop two runs from writing into the same
# workspace by accident. A local `mkdir`-based lock (atomic on every POSIX
# filesystem, no distributed-lock machinery). Sourced by bin/agent. Must
# not be executed directly.
set -euo pipefail

# workspace_lock_dir <workspace>
# The lock is a DIRECTORY (mkdir is the atomic primitive — two concurrent
# `mkdir` calls for the same path never both succeed) holding one `info`
# file with the current holder's identity.
workspace_lock_dir() { printf '%s.d\n' "$(state_lock_file "$1")"; }
workspace_lock_info_file() { printf '%s/info\n' "$(workspace_lock_dir "$1")"; }

# workspace_lock_info <workspace>
# Prints "run_id<TAB>pid<TAB>hostname<TAB>created_at", or nothing if unlocked.
workspace_lock_info() { cat "$(workspace_lock_info_file "$1")" 2>/dev/null || true; }

workspace_lock_is_locked() { [ -d "$(workspace_lock_dir "$1")" ]; }

# workspace_lock_is_stale <workspace>
# A lock with no readable info file is treated as corrupt/stale (safe to
# reclaim). Otherwise: a different hostname means we CANNOT verify liveness
# (the PID namespace isn't ours) — never auto-break a lock we can't verify,
# per spec ("não simplesmente delete lock porque PID não existe sem
# considerar hostname/reboot"). Same hostname: stale iff the PID is gone.
workspace_lock_is_stale() {
  local workspace="$1" info run_id pid host created here
  info="$(workspace_lock_info "$workspace")"
  [ -z "$info" ] && return 0
  IFS=$'\t' read -r run_id pid host created <<< "$info"
  here="$(hostname 2>/dev/null || echo unknown)"
  [ "$host" != "$here" ] && return 1
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}

# workspace_lock_acquire <workspace> <run_id>
# Returns 0 and holds the lock, or 1 with a stderr message naming the
# current holder. Automatically reclaims a STALE lock (same host, dead
# PID, or unreadable info) before trying once more; never touches a lock
# it can't verify as stale.
workspace_lock_acquire() {
  local workspace="$1" run_id="$2" lockdir infofile
  lockdir="$(workspace_lock_dir "$workspace")"
  infofile="$lockdir/info"
  mkdir -p "$(dirname "$lockdir")" 2>/dev/null || true

  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\n' "$run_id" "$$" "$(hostname 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$infofile"
    return 0
  fi

  if workspace_lock_is_stale "$workspace"; then
    echo "workspace_lock: reclaiming a stale lock at $lockdir" >&2
    rm -rf "$lockdir"
    if mkdir "$lockdir" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$run_id" "$$" "$(hostname 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$infofile"
      return 0
    fi
  fi

  echo "workspace_lock: another run already holds this workspace: $(workspace_lock_info "$workspace")" >&2
  return 1
}

# workspace_lock_release <workspace> <run_id>
# Only removes the lock when it's still OWNED by run_id — never releases a
# lock some other run (or a since-reclaimed stale lock) now holds.
workspace_lock_release() {
  local workspace="$1" run_id="$2" info owner
  info="$(workspace_lock_info "$workspace")"
  [ -z "$info" ] && return 0
  owner="$(printf '%s' "$info" | cut -f1)"
  [ "$owner" = "$run_id" ] && rm -rf "$(workspace_lock_dir "$workspace")"
  return 0
}

# workspace_lock_force_unlock <workspace>
# `agent unlock` — an explicit human override. Always removes the lock
# regardless of staleness, and always prints what it did (never silent).
workspace_lock_force_unlock() {
  local workspace="$1" info
  info="$(workspace_lock_info "$workspace")"
  if [ -z "$info" ]; then
    echo "no lock held for this workspace"
    return 0
  fi
  echo "removing lock: $info"
  rm -rf "$(workspace_lock_dir "$workspace")"
}
