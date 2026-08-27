#!/usr/bin/env bash
# P3.4: update discovery. `agent update check` — asks each component's
# upstream "what is the newest published version" and compares it to what is
# installed. This module NEVER installs, downgrades, writes config, or calls
# an LLM. Its only side effects are outbound read-only registry requests
# (npm/PyPI/component-specific), each with a short timeout, and it degrades
# to "unknown" (never a guess) when offline. Sourced by bin/agent and
# scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_UPDATE_DISC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _update_registry_query <scheme> <pkg> [channel]
# The single network seam. Prints a bare version string or nothing.
# Tests set AGENT_UPDATE_REGISTRY_FIXTURE to a script that takes
# "<scheme> <pkg> <channel>" and prints a version, so no unit test touches
# the real network. AGENT_UPDATE_OFFLINE=1 forces "nothing" (used to prove
# the offline path). For npm, `channel` selects a dist-tag (default latest);
# dsh + its bundles are published on "next".
_update_registry_query() {
  local scheme="$1" pkg="$2" channel="${3:-latest}"
  if [ -n "${AGENT_UPDATE_REGISTRY_FIXTURE:-}" ]; then
    "$AGENT_UPDATE_REGISTRY_FIXTURE" "$scheme" "$pkg" "$channel" 2>/dev/null
    return 0
  fi
  [ "${AGENT_UPDATE_OFFLINE:-0}" = "1" ] && return 0

  case "$scheme" in
    npm|bundle)
      command -v npm >/dev/null 2>&1 || return 0
      local v
      v="$(npm view "$pkg" "dist-tags.$channel" --fetch-timeout=10000 2>/dev/null | tr -d '[:space:]')"
      [ -z "$v" ] && v="$(npm view "$pkg" version --fetch-timeout=10000 2>/dev/null | tr -d '[:space:]')"
      printf '%s' "$v"
      ;;
    pypi)
      command -v curl >/dev/null 2>&1 || return 0
      curl -fsS -m 10 "https://pypi.org/pypi/$pkg/json" 2>/dev/null \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).info.version||""))}catch{}})' 2>/dev/null
      ;;
    *) return 0 ;;
  esac
}

# _update_source_scheme <source-string>  e.g. "npm:@deepseek-ai/dsh" -> "npm"
_update_source_scheme() { printf '%s' "${1%%:*}"; }
_update_source_pkg()    { case "$1" in *:*) printf '%s' "${1#*:}" ;; *) printf '' ;; esac; }

# update_available_version <component>
# The newest published version discoverable for this component, or empty.
# agent-reach is asked via its own `check-update` when that CLI is present
# (spec: prefer the upstream mechanism), else via npm.
update_available_version() {
  local component="$1" source scheme pkg channel
  source="$(compat_source "$component")"
  scheme="$(_update_source_scheme "$source")"
  pkg="$(_update_source_pkg "$source")"
  channel="$(compat_channel "$component")"

  if [ "$component" = "agent-reach" ] && command -v agent-reach >/dev/null 2>&1 && [ -z "${AGENT_UPDATE_REGISTRY_FIXTURE:-}" ]; then
    local raw
    raw="$(agent-reach check-update 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?' | tail -1)"
    [ -n "$raw" ] && { printf '%s' "$raw"; return 0; }
  fi

  case "$scheme" in
    npm|bundle|pypi) _update_registry_query "$scheme" "$pkg" "$channel" ;;
    *) return 0 ;;
  esac
}

# update_component_status <installed> <available> <scheme>
#   not_applicable  system tool (out of scope)
#   not_installed   nothing installed
#   unknown         could not reach the registry
#   up_to_date      installed >= available
#   update_available
#   ahead           installed is newer than the newest published (prerelease)
update_component_status() {
  local installed="$1" available="$2" scheme="$3"
  case "$scheme" in npm|bundle|pypi) ;; *) echo "not_applicable"; return 0 ;; esac
  [ -z "$installed" ] && { echo "not_installed"; return 0; }
  [ -z "$available" ] && { echo "unknown"; return 0; }
  [ "$installed" = "$available" ] && { echo "up_to_date"; return 0; }
  case "$(version_drift_compare "$installed" "$available")" in
    older)   echo "update_available" ;;
    newer)   echo "ahead" ;;
    equal)   echo "up_to_date" ;;
    *)       echo "update_available" ;;  # can't order -> surface it, don't hide it
  esac
}

# update_check
# One TSV row per component:
#   name  installed  available  scheme  status  critical
update_check() {
  local component installed source scheme available status critical
  while IFS= read -r component; do
    [ -n "$component" ] || continue
    installed="$(inventory_detect_version "$component")"
    source="$(compat_source "$component")"
    scheme="$(_update_source_scheme "$source")"
    available="$(update_available_version "$component")"
    status="$(update_component_status "$installed" "$available" "$scheme")"
    if compat_is_critical "$component"; then critical="true"; else critical="false"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$component" "${installed:--}" "${available:--}" "${scheme:--}" "$status" "$critical"
  done < <(compat_components)
}

update_check_json() {
  update_check | node "$_UPDATE_DISC_LIB_DIR/json-tools.mjs" update-check-build
}

# update_check_print
# Human table. Returns 0 always — `check` is informational and never a gate.
update_check_print() {
  local component installed available scheme status critical any_update=0
  printf '%-18s %-14s %-14s %-18s %s\n' COMPONENT INSTALLED AVAILABLE STATUS ""
  while IFS=$'\t' read -r component installed available scheme status critical; do
    [ -n "$component" ] || continue
    [ "$installed" = "-" ] && installed="(missing)"
    [ "$available" = "-" ] && available="—"
    [ "$status" = "update_available" ] && any_update=1
    printf '%-18s %-14s %-14s %-18s %s\n' \
      "$component" "$installed" "$available" "$status" \
      "$([ "$critical" = "true" ] && printf '[critical]')"
  done < <(update_check)
  echo
  if [ "$any_update" -eq 1 ]; then
    echo "updates available. Next: 'agent update plan' (no changes are made) then 'agent update apply <component>'."
  else
    echo "everything discoverable is up to date (system tools are out of scope — upgrade those via the OS)."
  fi
  echo "note: 'agent update check' made zero changes to this machine and zero LLM calls."
}
