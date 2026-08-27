#!/usr/bin/env bash
# P2.17: retention / cleanup for the run journal. NEVER deletes a run whose
# state is non-terminal (an active run, or an INTERRUPTED one still
# recoverable via `agent resume`) and NEVER touches anything inside the
# target project's own repo — only our own state dir. Sourced by bin/agent.
# Must not be executed directly.
set -euo pipefail

_CLEANUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CLEANUP_ROOT_DIR="$(cd "$_CLEANUP_LIB_DIR/.." && pwd)"
_CLEANUP_RUNTIME_POLICY="$_CLEANUP_ROOT_DIR/policies/runtime.yaml"

_cleanup_run_field() {
  node "$_CLEANUP_LIB_DIR/json-tools.mjs" get-field "$2" < "$1/run.json" 2>/dev/null
}

# cleanup_apply_retention [workspace]
# Applies policies/runtime.yaml's runs.retention_days / .retention_max_per_project.
# Scoped to one project's runs when a workspace is given, otherwise every
# project under the state dir. Prints a one-line summary.
cleanup_apply_retention() {
  local workspace="${1:-}"
  local retention_days retention_max
  retention_days="$(policy_get "$_CLEANUP_RUNTIME_POLICY" runs retention_days 30)"
  retention_max="$(policy_get "$_CLEANUP_RUNTIME_POLICY" runs retention_max_per_project 100)"

  local -a project_dirs=()
  if [ -n "$workspace" ]; then
    local pd
    pd="$(state_project_runs_dir "$workspace")"
    [ -d "$pd" ] && project_dirs=("$pd")
  else
    local runs_root
    runs_root="$(state_runs_root_dir)"
    if [ -d "$runs_root" ]; then
      mapfile -t project_dirs < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi
  fi

  local removed=0 kept=0 project_dir now_epoch
  now_epoch="$(date -u +%s)"
  for project_dir in "${project_dirs[@]}"; do
    [ -d "$project_dir" ] || continue
    local -a run_dirs=()
    mapfile -t run_dirs < <(find "$project_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)

    local idx=0 rd state started started_epoch age_days delete
    for rd in "${run_dirs[@]}"; do
      idx=$((idx + 1))
      [ -f "$rd/run.json" ] || continue
      state="$(_cleanup_run_field "$rd" state)"
      if ! run_state_is_terminal "$state" 2>/dev/null; then
        kept=$((kept + 1))
        continue
      fi

      delete=0
      [ "$idx" -gt "$retention_max" ] && delete=1

      started="$(_cleanup_run_field "$rd" started_at)"
      if [ -n "$started" ]; then
        started_epoch="$(node -e 'const t=Date.parse(process.argv[1]);process.stdout.write(Number.isNaN(t)?"":String(Math.floor(t/1000)))' "$started" 2>/dev/null)"
        if [ -n "$started_epoch" ]; then
          age_days=$(( (now_epoch - started_epoch) / 86400 ))
          [ "$age_days" -gt "$retention_days" ] && delete=1
        fi
      fi

      if [ "$delete" -eq 1 ]; then
        rm -rf "$rd"
        removed=$((removed + 1))
      else
        kept=$((kept + 1))
      fi
    done
  done
  echo "cleanup: removed $removed run(s), kept $kept run(s) (retention: ${retention_days}d / ${retention_max} per project; active and interrupted runs are never removed)"
}
