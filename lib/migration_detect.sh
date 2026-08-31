#!/usr/bin/env bash
# P3.7: detect config / skill / data migration concerns BEFORE an update is
# applied, so `agent update plan` and `agent update apply` can warn (and, for
# an irreversible data migration, refuse the "clean rollback" promise).
# Deterministic — driven by the component, the semver bump size, and the
# known migration notes in compat.yaml. No LLM. Sourced by bin/agent. Must
# not be executed directly.
set -euo pipefail

# migration_detect <component> <current> <candidate>
# Emits:
#   severity: none | reversible | irreversible | unknown
#   concern: <one per line>
migration_detect() {
  local component="$1" current="$2" candidate="$3"
  local bump; bump="$(_plan_semver_bump "$current" "$candidate")"
  local severity="reversible"
  local -a concerns=()

  case "$component" in
    claude-mem)
      if [ "$bump" = "major" ]; then
        severity="irreversible"
        concerns+=("a claude-mem MAJOR upgrade can run a one-way data migration on ~/.claude-mem/ (observations DB, vector store) — restoring the old binary will NOT un-migrate that data")
        concerns+=("snapshot settings.json + checksum the storage dir before applying; treat rollback as PARTIAL")
      else
        concerns+=("worker restart + Claude Code plugin re-registration (npx claude-mem install) after the update")
      fi
      concerns+=("verify: MCP search tools, SessionStart injection, provider/auth settings, context limits")
      ;;
    graphify)
      concerns+=("graphify install rewrites SKILL.md / the CLAUDE.md graphify section / the PreToolUse hook")
      concerns+=("the SKILL.md install location has historically differed by platform — verify the real path after install, do not trust the installer exit code")
      ;;
    agent-reach)
      concerns+=("skill refresh is explicit — an update does not auto-refresh SKILL.md")
      concerns+=("verify no new research channels were enabled and cookies were not touched")
      ;;
    deepseek-harness)
      concerns+=("config schema, profile format, Code Mode, and provider identifiers can change between dev-preview releases")
      concerns+=("re-run scripts/configure.sh after the update; then verify EVERY required capability probe")
      ;;
    claude-code|codex)
      concerns+=("the bundle may pull a new Claude Agent SDK / Codex wrapper with changed auth or tool behaviour")
      concerns+=("verify the subscription login still works and no generic child API key forwarding was introduced (see policies/safety.yaml)")
      ;;
    node|git|pnpm|bun|python|uv)
      severity="reversible"
      concerns+=("system component — the OS package manager owns rollback; out of \`agent update\` scope")
      ;;
  esac

  if [ "$bump" = "unknown" ] || [ -z "$bump" ]; then
    severity="unknown"
    concerns+=("could not determine the version-change size ($current -> $candidate) — treat as potentially breaking")
  fi

  local notes; notes="$(compat_migration_notes "$component")"
  [ -n "$notes" ] && concerns+=("compat.yaml: $notes")

  echo "severity: $severity"
  local c
  for c in "${concerns[@]}"; do echo "concern: $c"; done
}

# migration_is_irreversible <component> <current> <candidate>
migration_is_irreversible() {
  [ "$(migration_detect "$1" "$2" "$3" | sed -n 's/^severity: //p')" = "irreversible" ]
}
