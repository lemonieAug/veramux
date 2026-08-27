#!/usr/bin/env bash
# P2.8 (timeouts) + the shared mechanism behind P2.16's `agent cancel`.
#
# DSH's own subagent providers document "No wall-clock timeout" as a known
# limitation (docs/upstream-findings.md P2 section) — imposing a deadline on
# a `dsh --profile ... "..."` call is genuinely ours to build. Cleanup is
# NOT reinvented, though: we send SIGTERM to the `dsh` process itself, which
# already wires SIGTERM to a full graceful context/subprocess-tree disposal
# (confirmed in apps/cli/src/profile-boot.ts + docs/subsystems/subprocess.md
# — SIGTERM -> grace -> SIGKILL, tree-scoped). We prefer GNU coreutils
# `timeout` (present on any normal Linux VPS, forwards external signals to
# the child since coreutils 8.24) for the deadline+escalation itself, and
# fall back to an equivalent small bash loop only when `timeout` is absent.
#
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

proc_timeout_backend_available() { command -v timeout >/dev/null 2>&1; }

proc_track_path() { printf '%s/active.pid\n' "$1"; }
proc_cancel_marker_path() { printf '%s/cancel-requested\n' "$1"; }

proc_track_write() {
  local run_dir="$1" pid="$2"
  printf '%s\t%s\t%s\n' "$(hostname 2>/dev/null || echo unknown)" "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$(proc_track_path "$run_dir")"
}
proc_track_clear() { rm -f "$(proc_track_path "$1")" 2>/dev/null || true; }
proc_track_read() { cat "$(proc_track_path "$1")" 2>/dev/null || true; }

# proc_cancel_request <run_dir>
# Writes the cancel marker (checked by proc_was_cancelled — orchestrate.sh
# must consult this AFTER every dsh call and never trust a post-SIGTERM 0
# exit code as success once it's set) and best-effort signals the tracked
# PID. Returns 1 (marker still written) when there was nothing live to
# signal — the run may have already moved past this call.
proc_cancel_request() {
  local run_dir="$1"
  mkdir -p "$run_dir" 2>/dev/null || true
  : > "$(proc_cancel_marker_path "$run_dir")"
  local line pid
  line="$(proc_track_read "$run_dir")"
  [ -z "$line" ] && return 1
  pid="$(printf '%s' "$line" | cut -f2)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    return 0
  fi
  return 1
}

proc_cancel_requested() { [ -f "$(proc_cancel_marker_path "$1")" ]; }
proc_cancel_clear_marker() { rm -f "$(proc_cancel_marker_path "$1")" 2>/dev/null || true; }

# _proc_wait_with_fallback_timeout <pid> <timeout_s> <grace_s>
# Used only when GNU `timeout` isn't on PATH. Mirrors its own contract:
# returns 124 specifically when OUR deadline (not the child's own exit) is
# what ended the process, so lib/failures.sh's exit-code mapping applies
# identically regardless of which backend ran.
_proc_wait_with_fallback_timeout() {
  local pid="$1" timeout_s="$2" grace_s="$3"
  local flag
  flag="$(mktemp "${TMPDIR:-/tmp}/agent-proc-timeout.XXXXXX")"
  rm -f "$flag"
  (
    sleep "$timeout_s"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$flag"
      kill -TERM "$pid" 2>/dev/null || true
      sleep "$grace_s"
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
  ) &
  local watcher_pid=$!
  local code=0
  wait "$pid" 2>/dev/null || code=$?
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  if [ -f "$flag" ]; then
    rm -f "$flag"
    return 124
  fi
  return "$code"
}

# proc_call_with_timeout <run_dir> <timeout_s> <grace_s> <out_file> -- <cmd...>
# Runs cmd with stdout+stderr collected into out_file, enforces the deadline,
# tracks the PID for external `agent cancel` (P2.16), and always clears that
# tracking on the way out (no orphaned tracking entries). Exit code 124 means
# OUR deadline fired; any other code is the wrapped command's own.
proc_call_with_timeout() {
  local run_dir="$1" timeout_s="$2" grace_s="$3" out_file="$4"; shift 4
  [ "${1:-}" = "--" ] && shift

  local pid code=0
  if proc_timeout_backend_available; then
    timeout --signal=TERM --kill-after="${grace_s}s" "${timeout_s}s" "$@" > "$out_file" 2>&1 &
    pid=$!
    proc_track_write "$run_dir" "$pid"
    wait "$pid" 2>/dev/null || code=$?
    proc_track_clear "$run_dir"
    return "$code"
  fi

  "$@" > "$out_file" 2>&1 &
  pid=$!
  proc_track_write "$run_dir" "$pid"
  _proc_wait_with_fallback_timeout "$pid" "$timeout_s" "$grace_s" || code=$?
  proc_track_clear "$run_dir"
  return "$code"
}
