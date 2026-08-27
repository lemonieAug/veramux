#!/usr/bin/env bash
# P2.4/P2.5: where operational state (run journals, locks) lives on disk.
# Never inside the target project's own repo (spec: run journals are ours,
# not the user's project's) — an XDG-style directory under the user's own
# home, overridable for tests via AGENT_STATE_HOME. Sourced by bin/agent and
# scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_STATE_PATHS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# state_root_dir
# AGENT_STATE_HOME (test/manual override) -> XDG_STATE_HOME/agent-stack ->
# ~/.local/state/agent-stack. This is OUR state, not the target project's —
# never written under the workspace being operated on.
state_root_dir() {
  if [ -n "${AGENT_STATE_HOME:-}" ]; then
    printf '%s\n' "$AGENT_STATE_HOME"
  elif [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s/agent-stack\n' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/agent-stack\n' "$HOME"
  fi
}

state_runs_root_dir() { printf '%s/runs\n' "$(state_root_dir)"; }
state_locks_dir() { printf '%s/locks\n' "$(state_root_dir)"; }
state_projects_dir() { printf '%s/projects\n' "$(state_root_dir)"; }

# P3: maintenance state — pre-update config snapshots (P3.8), user backups
# (P3.18), isolated update staging areas (P3.6), and benchmark results
# (P3.12/P3.13). All under the same state root, never inside a target repo.
state_snapshots_dir() { printf '%s/snapshots\n' "$(state_root_dir)"; }
state_backups_dir() { printf '%s/backups\n' "$(state_root_dir)"; }
state_staging_dir() { printf '%s/staging\n' "$(state_root_dir)"; }
state_benchmark_dir() { printf '%s/benchmark\n' "$(state_root_dir)"; }

# state_project_root <workspace>
# The stable root a project-id is derived from: a git repo's toplevel (so
# running from a subdirectory still maps to the same project), or the
# resolved workspace path itself when it isn't a git repo.
state_project_root() {
  local workspace="$1"
  if command -v project_is_git_repo >/dev/null 2>&1 && project_is_git_repo "$workspace" 2>/dev/null; then
    git -C "$workspace" rev-parse --show-toplevel 2>/dev/null && return 0
  fi
  printf '%s\n' "$workspace"
}

# state_project_id <workspace>
# Stable, filesystem-safe identifier: sanitized basename + 8-hex-char hash
# of the full resolved root path (see lib/json-tools.mjs `project-id`).
state_project_id() {
  local workspace="$1" root
  root="$(state_project_root "$workspace")"
  node "$_STATE_PATHS_LIB_DIR/json-tools.mjs" project-id "$root"
}

state_project_runs_dir() {
  printf '%s/%s\n' "$(state_runs_root_dir)" "$(state_project_id "$1")"
}

# state_run_dir <workspace> <run_id>
state_run_dir() {
  printf '%s/%s\n' "$(state_project_runs_dir "$1")" "$2"
}

# state_lock_file <workspace>
state_lock_file() {
  printf '%s/%s.lock\n' "$(state_locks_dir)" "$(state_project_id "$1")"
}

# state_project_profile_cache <workspace>
# Where the P2.3 validation profile is cached (outside the target repo).
state_project_profile_cache() {
  printf '%s/%s/project-profile.json\n' "$(state_projects_dir)" "$(state_project_id "$1")"
}
