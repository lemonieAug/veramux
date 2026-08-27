#!/usr/bin/env bash
# Validation command detection + runner (P0.4).
# Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_VALIDATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# validation_pm_cmd <pm> <label>
# Delegates to lib/project_detect.sh's project_pm_command when that module
# is sourced; falls back to plain npm otherwise (this file is also used
# standalone by some tests/tools that don't need package-manager awareness).
validation_pm_cmd() {
  if command -v project_pm_command >/dev/null 2>&1; then
    project_pm_command "$1" "$2"
  elif [ "$2" = "test" ]; then
    echo "npm test"
  else
    echo "npm run $2"
  fi
}

validation_node_script() {
  local dir="$1" name="$2"
  node -e '
    const fs = require("fs");
    const [pkgPath, name] = process.argv.slice(1);
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
      const script = pkg.scripts && pkg.scripts[name];
      if (typeof script === "string" && script.trim()) process.stdout.write(script.trim());
    } catch {}
  ' "$dir/package.json" "$name" 2>/dev/null
}

# Prints "label<TAB>command" lines, in priority order: test, lint, typecheck,
# build. Never invents a command that isn't declared by the project itself.
#
# A project's .agent/config.yaml (P1.12) may override any of the four
# labels explicitly; when it defines at least one, those overrides
# COMPLETELY REPLACE auto-detection (predictable: either the project says
# exactly what to run, or we detect it — never a partial mix per run).
validation_detect_commands() {
  local dir="$1" force_build="${2:-false}"
  local emitted=0

  if command -v project_config_validation_command >/dev/null 2>&1; then
    local label override_cmd any_override=0
    local -a override_lines=()
    for label in test lint typecheck build; do
      override_cmd="$(project_config_validation_command "$dir" "$label")"
      if [ -n "$override_cmd" ]; then
        override_lines+=("$label"$'\t'"$override_cmd")
        any_override=1
      fi
    done
    if [ "$any_override" -eq 1 ]; then
      printf '%s\n' "${override_lines[@]}"
      return 0
    fi
  fi

  if [ -f "$dir/package.json" ]; then
    # P2.2/P2.3: the command prefix follows the PROJECT's own lockfile, not
    # whichever package manager happens to be on this machine. Falls back to
    # npm when lib/project_detect.sh isn't sourced (some callers/tests use
    # this file standalone).
    local pm="npm"
    if command -v project_pm_resolve >/dev/null 2>&1; then
      pm="$(project_pm_resolve "$dir" 2>/dev/null || echo npm)"
    fi

    local test_script lint_script typecheck_script build_script have_test=0 have_typecheck=0
    test_script="$(validation_node_script "$dir" test)"
    if [ -n "$test_script" ] && [ "$test_script" != 'echo "Error: no test specified" && exit 1' ]; then
      printf 'test\t%s\n' "$(validation_pm_cmd "$pm" test)"
      have_test=1
      emitted=1
    fi
    lint_script="$(validation_node_script "$dir" lint)"
    if [ -n "$lint_script" ]; then
      printf 'lint\t%s\n' "$(validation_pm_cmd "$pm" lint)"
      emitted=1
    fi
    typecheck_script="$(validation_node_script "$dir" typecheck)"
    if [ -n "$typecheck_script" ]; then
      printf 'typecheck\t%s\n' "$(validation_pm_cmd "$pm" typecheck)"
      have_typecheck=1
      emitted=1
    fi
    build_script="$(validation_node_script "$dir" build)"
    if [ -n "$build_script" ]; then
      if [ "$force_build" = "true" ] || { [ "$have_test" -eq 0 ] && [ "$have_typecheck" -eq 0 ]; }; then
        printf 'build\t%s\n' "$(validation_pm_cmd "$pm" build)"
        emitted=1
      fi
    fi
    [ "$emitted" -eq 1 ] && return 0
  fi

  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/requirements.txt" ]; then
    local pytest_available=0 ruff_configured=0 mypy_configured=0
    if env_has_cmd pytest || python3 -c 'import pytest' >/dev/null 2>&1; then
      if [ -d "$dir/tests" ] || [ -d "$dir/test" ] || grep -qE '\[tool\.pytest' "$dir/pyproject.toml" 2>/dev/null; then
        pytest_available=1
      fi
    fi
    [ "$pytest_available" -eq 1 ] && printf 'test\tpython3 -m pytest\n' && emitted=1

    if grep -qE '\[tool\.ruff\]' "$dir/pyproject.toml" 2>/dev/null || [ -f "$dir/ruff.toml" ] || [ -f "$dir/.ruff.toml" ]; then
      ruff_configured=1
    fi
    if env_has_cmd ruff && [ "$ruff_configured" -eq 1 ]; then
      printf 'lint\truff check .\n'
      emitted=1
    fi

    if grep -qE '\[tool\.mypy\]' "$dir/pyproject.toml" 2>/dev/null || [ -f "$dir/mypy.ini" ]; then
      mypy_configured=1
    elif [ -f "$dir/setup.cfg" ] && grep -q '\[mypy\]' "$dir/setup.cfg" 2>/dev/null; then
      mypy_configured=1
    fi
    if env_has_cmd mypy && [ "$mypy_configured" -eq 1 ]; then
      printf 'typecheck\tmypy .\n'
      emitted=1
    fi
    [ "$emitted" -eq 1 ] && return 0
  fi

  if [ -f "$dir/Makefile" ]; then
    local target
    for target in test lint typecheck build; do
      if [ "$target" = "build" ] && [ "$force_build" != "true" ]; then
        grep -qE '^test:|^lint:|^typecheck:' "$dir/Makefile" >/dev/null 2>&1 && continue
      fi
      if grep -qE "^${target}:" "$dir/Makefile" 2>/dev/null; then
        printf '%s\tmake %s\n' "$target" "$target"
        emitted=1
      fi
    done
    [ "$emitted" -eq 1 ] && return 0
  fi

  return 0
}

# Runs each "label<TAB>command" pair from stdin inside $dir, logging what it
# runs (the project's own script text is treated as project code, not ours:
# it is always echoed before execution). Writes the structured JSON result
# to $out_json. Returns 1 if any command failed (caller decides what that means).
validation_run() {
  local dir="$1" out_json="$2"
  local status_lines="" any_failed=0
  local label command

  while IFS=$'\t' read -r label command; do
    [ -z "$label" ] && continue
    echo "+ validation[$label]: $command" >&2
    if (cd "$dir" && bash -c "$command") >&2; then
      status_lines+="passed"$'\t'"$label: $command"$'\n'
    else
      status_lines+="failed"$'\t'"$label: $command"$'\n'
      any_failed=1
    fi
  done

  printf '%s' "$status_lines" | node "$_VALIDATION_LIB_DIR/json-tools.mjs" build-validation-result > "$out_json"
  [ "$any_failed" -eq 0 ]
}
