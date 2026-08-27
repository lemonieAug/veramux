#!/usr/bin/env bash
# P3: the `agent update <subcommand>` dispatcher. Grows one phase at a time
# (check -> plan -> apply -> rollback). `check` and `plan` are strictly
# read-only and make ZERO changes to the machine and ZERO LLM calls; `apply`
# and `rollback` are the only mutating verbs and each takes an explicit
# version / snapshot id. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

update_cli_usage() {
  cat <<'EOF'
Usage: agent update <command>

  check                 Discover newer published versions (read-only, no LLM)
  plan [<component>]    Show exactly what an update would do (read-only, no LLM)
  apply <component> [--to <version>] [--yes]
                        Snapshot -> stage -> verify -> apply -> post-verify
  rollback [<snapshot-id>]
                        Restore the config state from a pre-update snapshot

'check' and 'plan' never modify anything. 'apply'/'rollback' are the only
commands that change installed components, and they always snapshot first.
EOF
}

update_cli_dispatch() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    check)
      update_check_print
      ;;
    plan)
      if command -v update_plan_print >/dev/null 2>&1; then
        update_plan_print "${1:-}"
      else
        echo "error: 'agent update plan' is not available in this build" >&2
        return 1
      fi
      ;;
    apply)
      if command -v update_apply_run >/dev/null 2>&1; then
        update_apply_run "$@"
      else
        echo "error: 'agent update apply' is not available in this build" >&2
        return 1
      fi
      ;;
    rollback)
      if command -v rollback_run >/dev/null 2>&1; then
        rollback_run "${1:-}"
      else
        echo "error: 'agent update rollback' is not available in this build" >&2
        return 1
      fi
      ;;
    ""|-h|--help|help)
      update_cli_usage
      ;;
    *)
      echo "error: unknown 'agent update' command: $sub" >&2
      update_cli_usage >&2
      return 1
      ;;
  esac
}
