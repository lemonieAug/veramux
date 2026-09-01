#!/usr/bin/env bash
# P3.2: deterministic component inventory. For every component in
# compat.yaml, resolve the ACTUALLY installed version from the right place
# (a CLI's --version, a bundle's node_modules package.json, a system tool),
# not from a package manager's lockfile guess, and pair it with the tested
# version + compatibility status. Zero LLM, zero mutation. Sourced by
# bin/agent and scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_INVENTORY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _inv_semver <text>
# First MAJOR.MINOR.PATCH (or MAJOR.MINOR) run in the text, suffixes kept
# only up to the first whitespace. "git version 2.49.0.windows.1" -> 2.49.0,
# "v22.23.2" -> 22.23.2, "uv 0.12.5 (abc...)" -> 0.12.5.
_inv_semver() {
  # MAJOR.MINOR[.PATCH][-prerelease] — a trailing "-rc.2" is kept, a
  # platform tail like ".windows.1" (git) is not.
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?' | head -1
}

# _inv_cli_version <cmd> [args...]
# Runs `<cmd> --version` (or the given args) and extracts a version. Prints
# empty when the command is absent or produces nothing parseable.
_inv_cli_version() {
  local cmd="$1"; shift
  env_has_cmd "$cmd" || return 0
  local raw
  if [ "$#" -gt 0 ]; then
    raw="$("$cmd" "$@" 2>/dev/null | head -3)"
  else
    raw="$("$cmd" --version 2>/dev/null | head -3)"
  fi
  _inv_semver "$raw"
}

# _inv_bundle_pkg_version <package.json path>
_inv_bundle_pkg_version() {
  [ -f "$1" ] || return 0
  node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version||"")}catch{}' "$1" 2>/dev/null
}

# inventory_detect_version <component>
# The one dispatch point. Every branch is a pure read. Tests may set
# AGENT_INVENTORY_FIXTURE to a script taking "<component>" and printing a
# version, so a unit test can model an installed component without it
# actually being on the box.
inventory_detect_version() {
  local component="$1" dsh_home
  if [ -n "${AGENT_INVENTORY_FIXTURE:-}" ]; then
    "$AGENT_INVENTORY_FIXTURE" "$component" 2>/dev/null
    return 0
  fi
  dsh_home="$(env_dsh_home)"
  case "$component" in
    deepseek-harness) _inv_cli_version dsh ;;
    # The bundle package's OWN version (tracks dsh's scheme) — this is the
    # unit `dsh plugin add` installs and the unit compat.yaml pins. The
    # transitive SDK / wrapper version is a detail probe, see
    # inventory_detail_version.
    claude-code)      _inv_bundle_pkg_version "$dsh_home/profiles/lead/node_modules/@deepseek-ai/dsh-subagent-claude-code/package.json" ;;
    codex)            _inv_bundle_pkg_version "$dsh_home/profiles/reviewer/node_modules/@deepseek-ai/dsh-subagent-codex/package.json" ;;
    claude-mem)       _inv_cli_version claude-mem ;;
    graphify)         _inv_cli_version graphify ;;
    agent-reach)      _inv_cli_version agent-reach ;;
    node)             _inv_cli_version node ;;
    pnpm)             _inv_cli_version pnpm ;;
    bun)              _inv_cli_version bun ;;
    python)           _inv_cli_version python; [ -n "$(_inv_cli_version python)" ] || _inv_cli_version python3 ;;
    uv)               _inv_cli_version uv ;;
    git)              _inv_cli_version git ;;
    *)                return 0 ;;
  esac
}

# inventory_detail_version <component>
# The transitive payload version worth showing alongside a bundle: the
# Claude Agent SDK inside the lead bundle, the Codex wrapper inside the
# reviewer bundle. Empty for everything else. Reuses lib/version_drift.sh's
# existing probes so there is one implementation.
inventory_detail_version() {
  local dsh_home
  dsh_home="$(env_dsh_home)"
  case "$1" in
    claude-code) version_drift_installed_claude_agent_sdk "$dsh_home" ;;
    codex)       version_drift_installed_codex_wrapper "$dsh_home" ;;
    *)           return 0 ;;
  esac
}

# inventory_collect [--probe]
# One TSV row per component:
#   name  installed  source  tested  status  critical  capabilities(comma)
# `installed` is "-" for a missing component. `status` is compat_status
# (pure version/manifest comparison) UNLESS --probe is given AND
# lib/capability_probe.sh is sourced, in which case a component whose
# required capabilities probe as verifiably absent is reported INCOMPATIBLE
# regardless of its version. --probe runs deterministic checks only (file
# reads, --help greps, a short-timeout curl) — never an LLM or quota call.
inventory_collect() {
  local probe=0
  [ "${1:-}" = "--probe" ] && probe=1
  local component installed tested source status critical caps
  while IFS= read -r component; do
    [ -n "$component" ] || continue
    installed="$(inventory_detect_version "$component")"
    tested="$(compat_tested_version "$component")"
    source="$(compat_source "$component")"
    status="$(compat_status "$component" "$installed")"
    if [ "$probe" -eq 1 ] && [ -n "$installed" ] && command -v capability_verdict >/dev/null 2>&1; then
      if [ "$(capability_verdict "$component")" = "INCOMPATIBLE" ]; then
        status="INCOMPATIBLE"
      fi
    fi
    if compat_is_critical "$component"; then critical="true"; else critical="false"; fi
    caps="$(compat_required_capabilities "$component" | paste -sd, - 2>/dev/null || true)"
    # Tab is an IFS-whitespace character, so a downstream `IFS=$'\t' read`
    # collapses an empty middle field. Emit "-" for an absent version and
    # for empty capabilities; consumers map "-" back to null/empty.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$component" "${installed:--}" "${source:--}" "${tested:--}" "$status" "$critical" "${caps:--}"
  done < <(compat_components)
}

# inventory_json
# The TSV rows assembled into a JSON array of objects (schema in
# lib/json-tools.mjs `inventory-build`).
inventory_json() {
  inventory_collect "${1:-}" | node "$_INVENTORY_LIB_DIR/json-tools.mjs" inventory-build
}

# inventory_print [--probe]
# Human-readable table for `agent update check` / doctor.
inventory_print() {
  local component installed source tested status critical caps
  printf '%-18s %-14s %-14s %-16s %s\n' COMPONENT INSTALLED TESTED STATUS SOURCE
  while IFS=$'\t' read -r component installed source tested status critical caps; do
    [ -n "$component" ] || continue
    [ "$installed" = "-" ] && installed="(missing)"
    [ "$source" = "-" ] && source=""
    [ "$tested" = "-" ] && tested="?"
    printf '%-18s %-14s %-14s %-16s %s%s\n' \
      "$component" "$installed" "$tested" "$status" "$source" \
      "$([ "$critical" = "true" ] && printf '  [critical]')"
  done < <(inventory_collect "${1:-}")
}
