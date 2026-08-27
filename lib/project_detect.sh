#!/usr/bin/env bash
# Extended project ecosystem + package manager detection (P2.2/P2.3).
# Additive to lib/project.sh's P0 project_detect_ecosystem (node/python/make):
# this module adds Go/Rust/PHP/Java/Docker/generic tags, deterministic
# package-manager choice from lockfiles, and assembles the reusable
# "validation profile" object (P2.3). Evidence-based only — a manifest or
# lockfile's presence, never a content heuristic or "what's on this machine".
# Sourced by bin/agent and scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_PROJECT_DETECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# project_detect_ecosystems_extended <dir>
# One tag per line, in ADDITION to project_detect_ecosystem's node/python/make
# (never replaces it — existing callers of that P0 function are unaffected).
project_detect_ecosystems_extended() {
  local dir="$1"
  [ -f "$dir/go.mod" ] && echo "go"
  [ -f "$dir/Cargo.toml" ] && echo "rust"
  [ -f "$dir/composer.json" ] && echo "php"
  if [ -f "$dir/pom.xml" ] || ls "$dir"/build.gradle* >/dev/null 2>&1 || [ -f "$dir/gradlew" ]; then
    echo "java"
  fi
  if [ -f "$dir/Dockerfile" ] || ls "$dir"/docker-compose*.y*ml >/dev/null 2>&1; then
    echo "docker"
  fi
  if [ -f "$dir/justfile" ] || [ -f "$dir/Justfile" ]; then
    echo "just"
  fi
  return 0
}

# project_detect_package_manager <dir>
# Prints exactly one of: pnpm|yarn|npm|bun. Priority comes from the
# project's OWN lockfile — never from what happens to be installed on this
# machine (P2.2: "não escolha package manager apenas porque ele existe na
# máquina"). No package.json at all: returns 1, prints nothing. More than
# one lockfile present (genuine ambiguity, e.g. a half-migrated repo):
# returns 2, prints nothing to stdout and the candidates to stderr — callers
# must not guess; see project_pm_resolve for the documented fallback.
project_detect_package_manager() {
  local dir="$1"
  [ -f "$dir/package.json" ] || return 1

  local -a found=()
  [ -f "$dir/pnpm-lock.yaml" ] && found+=("pnpm")
  [ -f "$dir/yarn.lock" ] && found+=("yarn")
  [ -f "$dir/package-lock.json" ] && found+=("npm")
  { [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; } && found+=("bun")

  case "${#found[@]}" in
    0) printf 'npm\n'; return 0 ;;
    1) printf '%s\n' "${found[0]}"; return 0 ;;
    *)
      printf '%s\n' "${found[*]}" >&2
      return 2
      ;;
  esac
}

# project_pm_resolve <workspace>
# The one function callers should use. Precedence (documented in README):
# project .agent/config.yaml explicit override -> lockfile detection -> npm
# fallback with a warning on genuine ambiguity. Always prints exactly one of
# pnpm|yarn|npm|bun on stdout (or nothing if there's no package.json at all);
# ambiguity warnings go to stderr, never silently swallowed.
project_pm_resolve() {
  local workspace="$1" override="" detected="" code=0
  if command -v project_config_path >/dev/null 2>&1; then
    local cfg
    cfg="$(project_config_path "$workspace")"
    if [ -f "$cfg" ]; then
      override="$(policy_get "$cfg" validation package_manager "")"
    fi
  fi
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi

  local err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/agent-pm-ambiguity.XXXXXX")"
  detected="$(project_detect_package_manager "$workspace" 2>"$err_file")" || code=$?
  if [ "$code" -eq 2 ]; then
    echo "warning: ambiguous package manager for $workspace (multiple lockfiles: $(cat "$err_file" 2>/dev/null)); defaulting to npm. Set validation.package_manager in .agent/config.yaml to silence this." >&2
    rm -f "$err_file"
    printf 'npm\n'
    return 0
  fi
  rm -f "$err_file"
  [ "$code" -eq 1 ] && return 1
  printf '%s\n' "$detected"
}

# project_pm_command <pm> <label: test|lint|typecheck|build>
# Prints the idiomatic invocation for that package manager. `bun test`
# deliberately never appears here: Bun's CLI treats `test` as its own
# built-in test runner and does NOT run the package.json "test" script
# unless invoked as `bun run test` — using bare `bun test` would silently
# run the wrong thing for any project not using Bun's native runner.
project_pm_command() {
  local pm="$1" label="$2"
  case "$pm" in
    npm)  if [ "$label" = "test" ]; then echo "npm test"; else echo "npm run $label"; fi ;;
    pnpm) if [ "$label" = "test" ]; then echo "pnpm test"; else echo "pnpm run $label"; fi ;;
    yarn) echo "yarn $label" ;;
    bun)  echo "bun run $label" ;;
    *) return 1 ;;
  esac
}

# project_detect_framework <dir>
# Deliberately tiny — "quando óbvio", not a framework catalog. One line per
# hit at most for the handful of cases a single manifest field answers
# outright. Extend only when a new case is this cheap to detect correctly.
project_detect_framework() {
  local dir="$1"
  if [ -f "$dir/package.json" ]; then
    if grep -q '"next"[[:space:]]*:' "$dir/package.json" 2>/dev/null; then
      echo "next"
    elif [ -f "$dir/nuxt.config.ts" ] || [ -f "$dir/nuxt.config.js" ]; then
      echo "nuxt"
    fi
  fi
  return 0
}

# project_profile_build <workspace>
# Assembles the P2.3 validation-profile JSON object. Pure/read-only: does
# not write anything to disk itself (callers decide whether/where to cache
# it — see lib/journal.sh for the run-scoped copy). Always succeeds; an
# unrecognized project just gets empty arrays/fields.
project_profile_build() {
  local workspace="$1"
  {
    project_detect_ecosystem "$workspace" | while IFS= read -r lang; do
      [ -n "$lang" ] && printf 'language\t%s\n' "$lang"
    done
    project_detect_ecosystems_extended "$workspace" | while IFS= read -r lang; do
      [ -n "$lang" ] && printf 'language\t%s\n' "$lang"
    done
    project_detect_framework "$workspace" | while IFS= read -r fw; do
      [ -n "$fw" ] && printf 'framework\t%s\n' "$fw"
    done

    local pm=""
    pm="$(project_pm_resolve "$workspace" 2>/dev/null || true)"
    [ -n "$pm" ] && printf 'package_manager\t%s\n' "$pm"

    local commands label cmd
    commands="$(validation_detect_commands "$workspace" false)"
    if [ -n "$commands" ]; then
      while IFS=$'\t' read -r label cmd; do
        [ -n "$label" ] && printf 'validation\t%s\t%s\n' "$label" "$cmd"
      done <<< "$commands"
    fi

    printf 'detected_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local f
    for f in package.json pnpm-lock.yaml yarn.lock package-lock.json bun.lock bun.lockb \
             pyproject.toml requirements.txt uv.lock poetry.lock go.mod Cargo.toml \
             composer.json pom.xml build.gradle build.gradle.kts Makefile Dockerfile \
             justfile Justfile .agent/config.yaml; do
      [ -f "$workspace/$f" ] && printf 'source_file\t%s\n' "$f"
    done
  } | node "$_PROJECT_DETECT_LIB_DIR/json-tools.mjs" build-project-profile
}
