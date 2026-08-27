#!/usr/bin/env bash
# P2.17: retention/cleanup. Never removes an active or INTERRUPTED
# (resumable) run; never touches anything inside a target project's repo.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/run_lifecycle.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/journal.sh"
source "$ROOT_DIR/lib/cleanup.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

WORKSPACE="$TMP/repo"
mkdir -p "$WORKSPACE"
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" -c user.email=t@t.com -c user.name=t commit -q --allow-empty -m init

make_run() {
  local state="$1" started_at="$2"
  local run_id run_dir
  run_id="$(run_id_generate)"
  run_dir="$(journal_run_create "$WORKSPACE" "$run_id" "task" "abc" "false")"
  node "$ROOT_DIR/lib/json-tools.mjs" run-update "$run_dir/run.json" "started_at=$started_at" >/dev/null
  case "$state" in
    COMPLETED) journal_run_transition "$run_dir" CONTEXT; journal_run_transition "$run_dir" IMPLEMENTING; journal_run_transition "$run_dir" VALIDATING; journal_run_transition "$run_dir" COMPLETED ;;
    FAILED) journal_run_transition "$run_dir" CONTEXT; journal_run_transition "$run_dir" FAILED ;;
    INTERRUPTED) journal_run_transition "$run_dir" CONTEXT; journal_run_transition "$run_dir" INTERRUPTED ;;
    CREATED) : ;;
  esac
  printf '%s\n' "$run_dir"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
days_ago_iso() {
  local days="$1"
  node -e 'const d=new Date(Date.now()-Number(process.argv[1])*86400000);process.stdout.write(d.toISOString())' "$days"
}

# --- age-based retention: an old COMPLETED run is removed, a recent one isn't ---
old_completed="$(make_run COMPLETED "$(days_ago_iso 40)")"
recent_completed="$(make_run COMPLETED "$(now_iso)")"

out="$(cleanup_apply_retention "$WORKSPACE")"
assert_eq "1" "$([ ! -d "$old_completed" ] && echo 1 || echo 0)" "a COMPLETED run older than retention_days is removed"
assert_eq "1" "$([ -d "$recent_completed" ] && echo 1 || echo 0)" "a recent COMPLETED run is kept"
assert_contains "$out" "removed 1 run" "cleanup reports how many it removed"

# --- an active (non-terminal) run is NEVER removed, however old ---
rm -rf "$(state_project_runs_dir "$WORKSPACE")"
active_old="$(make_run CREATED "$(days_ago_iso 400)")"
cleanup_apply_retention "$WORKSPACE" >/dev/null
assert_eq "1" "$([ -d "$active_old" ] && echo 1 || echo 0)" "an active (CREATED) run is never removed by retention, regardless of age"

# --- an INTERRUPTED (still resumable) run is NEVER removed, however old ---
rm -rf "$(state_project_runs_dir "$WORKSPACE")"
interrupted_old="$(make_run INTERRUPTED "$(days_ago_iso 400)")"
cleanup_apply_retention "$WORKSPACE" >/dev/null
assert_eq "1" "$([ -d "$interrupted_old" ] && echo 1 || echo 0)" "an INTERRUPTED (resumable) run is never removed by retention"

# --- retention_max_per_project: only the oldest TERMINAL runs beyond the
# cap are removed, ranked among terminal runs by recency ---
rm -rf "$(state_project_runs_dir "$WORKSPACE")"
cat > "$TMP/state/runtime-override.yaml" <<'EOF'
runs:
  retention_days: 3650
  retention_max_per_project: 2
EOF
# Point the module at a tiny override policy for this one check.
_CLEANUP_RUNTIME_POLICY="$TMP/state/runtime-override.yaml"
r1="$(make_run COMPLETED "$(now_iso)")"; sleep 1
r2="$(make_run COMPLETED "$(now_iso)")"; sleep 1
r3="$(make_run COMPLETED "$(now_iso)")"
out2="$(cleanup_apply_retention "$WORKSPACE")"
assert_eq "1" "$([ ! -d "$r1" ] && echo 1 || echo 0)" "the oldest run beyond retention_max_per_project is removed"
assert_eq "1" "$([ -d "$r2" ] && echo 1 || echo 0)" "the 2nd-newest run is kept (within the cap of 2)"
assert_eq "1" "$([ -d "$r3" ] && echo 1 || echo 0)" "the newest run is kept"
assert_contains "$out2" "removed 1 run" "cleanup's per-project cap removed exactly the expected count"

report_and_exit
