#!/usr/bin/env bash
# P3.3: the compatibility layer over compat.yaml. Reads the manifest with
# lib/policy.sh's small readers and answers "is this installed version one
# we have actually tested / can support / have never seen / is too old", and
# "which capabilities does the stack depend on for this component". Version
# ordering is delegated to lib/version_drift.sh — this file never writes a
# second semver comparator. Sourced by bin/agent and scripts/doctor.sh.
# Must not be executed directly.
set -euo pipefail

_COMPAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_COMPAT_ROOT_DIR="$(cd "$_COMPAT_LIB_DIR/.." && pwd)"

compat_file() { printf '%s\n' "${AGENT_COMPAT_FILE:-$_COMPAT_ROOT_DIR/compat.yaml}"; }

# compat_components
# Every top-level component section in compat.yaml, one per line, in file
# order. `schema_version` is the only top-level scalar and is skipped.
compat_components() {
  awk '
    /^[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
      name = $1; sub(/:$/, "", name)
      if (name != "schema_version") print name
    }
  ' "$(compat_file)" 2>/dev/null
}

compat_has_component() {
  local target="$1" c
  while IFS= read -r c; do [ "$c" = "$target" ] && return 0; done < <(compat_components)
  return 1
}

# compat_field <component> <key> [default]
compat_field() {
  policy_get "$(compat_file)" "$1" "$2" "${3:-}"
}

compat_tested_version() { compat_field "$1" tested; }
compat_source()         { compat_field "$1" source; }
# compat_channel: the npm dist-tag this component follows. Defaults to
# "latest"; dsh and its bundles are a dev preview published on "next".
compat_channel()        { compat_field "$1" channel latest; }
compat_scope()          { compat_field "$1" scope; }
compat_version_probe()  { compat_field "$1" version_probe; }
compat_registry_probe() { compat_field "$1" registry_probe; }
compat_migration_notes(){ compat_field "$1" migration_notes; }
compat_rollback_note()  { compat_field "$1" rollback; }

compat_is_critical() {
  [ "$(compat_field "$1" critical false)" = "true" ]
}

# compat_required_capabilities <component> -> one capability slug per line
compat_required_capabilities() {
  policy_get_nested_list "$(compat_file)" "$1" required_capabilities
}

# _compat_major_minor <version> -> "MAJOR.MINOR" (leading numeric tuple only,
# prerelease/build suffixes ignored), or empty when unparseable.
_compat_major_minor() {
  printf '%s' "$1" | sed -nE 's/^([0-9]+)\.([0-9]+).*$/\1.\2/p'
}

# compat_status <component> <installed_version>
# Prints TESTED | SUPPORTED | NEWER_UNTESTED | OLDER | MISSING.
# INCOMPATIBLE is never returned here — it is a capability-probe verdict
# (lib/capability_probe.sh), layered on top of this by the inventory.
compat_status() {
  local component="$1" installed="$2" tested
  tested="$(compat_tested_version "$component")"

  [ -z "$installed" ] && { echo "MISSING"; return 0; }
  [ -z "$tested" ] && { echo "NEWER_UNTESTED"; return 0; }
  [ "$installed" = "$tested" ] && { echo "TESTED"; return 0; }

  local cmp
  cmp="$(version_drift_compare "$installed" "$tested")"
  local mm_installed mm_tested
  mm_installed="$(_compat_major_minor "$installed")"
  mm_tested="$(_compat_major_minor "$tested")"

  case "$cmp" in
    equal)  echo "TESTED" ;;
    older)  echo "OLDER" ;;
    newer)
      if [ -n "$mm_installed" ] && [ "$mm_installed" = "$mm_tested" ]; then
        echo "SUPPORTED"
      else
        echo "NEWER_UNTESTED"
      fi
      ;;
    *) echo "NEWER_UNTESTED" ;;
  esac
}

# compat_status_is_safe <status>
# The statuses that do NOT by themselves block normal operation. NEWER_
# UNTESTED / OLDER / INCOMPATIBLE / MISSING all warrant attention.
compat_status_is_safe() {
  case "$1" in
    TESTED|SUPPORTED) return 0 ;;
    *) return 1 ;;
  esac
}
