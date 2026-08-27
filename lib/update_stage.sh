#!/usr/bin/env bash
# P3.6: safe update staging. Before a candidate replaces a working install,
# try to verify it in ISOLATION — a temp npm prefix, an isolated uv tool
# environment — and check that the binary starts, reports the expected
# version, still exposes the subcommands the stack calls, and (where a
# staged install allows it) passes capability probes. The target project and
# the real global install are never touched. When isolation is not
# technically possible (a DSH profile mutation, a system runtime) the result
# is `staging_not_available`, which lib/update_plan.sh escalates the risk
# for. No LLM. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_STAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _stage_install <scheme> <pkg> <version> <dest-dir>
# The install seam. Tests set AGENT_STAGE_INSTALL_FIXTURE to a script taking
# "<scheme> <pkg> <version> <dest>" that populates <dest> (e.g. a fake
# node_modules/.bin/<name>), so no unit test hits the network. Returns
# nonzero on install failure.
_stage_install() {
  local scheme="$1" pkg="$2" version="$3" dest="$4"
  if [ -n "${AGENT_STAGE_INSTALL_FIXTURE:-}" ]; then
    "$AGENT_STAGE_INSTALL_FIXTURE" "$scheme" "$pkg" "$version" "$dest"
    return $?
  fi
  case "$scheme" in
    npm|bundle)
      command -v npm >/dev/null 2>&1 || return 3
      npm install --prefix "$dest" "$pkg@$version" --no-audit --no-fund --loglevel=error >/dev/null 2>&1
      ;;
    pypi)
      command -v uv >/dev/null 2>&1 || return 3
      uv venv "$dest/venv" >/dev/null 2>&1 || return 3
      uv pip install --python "$dest/venv" "$pkg==$version" >/dev/null 2>&1
      ;;
    *) return 4 ;;
  esac
}

# _stage_bin_dir <scheme> <dest>
_stage_bin_dir() {
  case "$1" in
    npm|bundle) printf '%s/node_modules/.bin' "$2" ;;
    pypi)       printf '%s/venv/bin' "$2" ;;
  esac
}

# stage_candidate <component> <candidate>
# Prints a result token on the LAST line of stdout:
#   staged_ok | staged_failed | staging_not_available
# Everything above it is the human-readable staging report.
stage_candidate() {
  local component="$1" candidate="$2"
  local source scheme pkg
  source="$(compat_source "$component")"
  scheme="$(_update_source_scheme "$source")"
  pkg="$(_update_source_pkg "$source")"

  case "$scheme" in
    system)
      echo "staging: $component is a system component — isolation is not applicable."
      echo "staging_not_available"; return 0 ;;
    bundle)
      if ! command -v dsh >/dev/null 2>&1 && [ -z "${AGENT_STAGE_INSTALL_FIXTURE:-}" ]; then
        echo "staging: a DSH profile bundle can only be verified by mutating the real profile (dsh plugin add) — refusing to do that in a staging step."
        echo "staging_not_available"; return 0
      fi ;;
  esac

  local stage_root dest
  stage_root="$(state_staging_dir)"
  dest="$stage_root/$(date -u +%Y%m%dT%H%M%SZ)-$component"
  mkdir -p "$dest"
  # The staging dir is disposable — clean it on the way out regardless.
  trap 'rm -rf "$dest" 2>/dev/null || true' RETURN

  echo "staging: installing $pkg@$candidate into $dest (isolated — the real install is untouched)"
  if ! _stage_install "$scheme" "$pkg" "$candidate" "$dest"; then
    echo "staging: isolated install FAILED"
    echo "staged_failed"; return 0
  fi

  local bindir; bindir="$(_stage_bin_dir "$scheme" "$dest")"
  local cli
  case "$component" in
    deepseek-harness) cli="dsh" ;;
    claude-mem) cli="claude-mem" ;;
    graphify) cli="graphify" ;;
    agent-reach) cli="agent-reach" ;;
    *) cli="$component" ;;
  esac

  local bin="$bindir/$cli"
  if [ ! -x "$bin" ] && [ ! -f "$bin" ]; then
    # some npm packages expose the bin under a different name — take the only
    # executable if there is exactly one
    local only
    only="$(find "$bindir" -maxdepth 1 -type f 2>/dev/null | head -2)"
    if [ "$(printf '%s\n' "$only" | grep -c .)" = "1" ]; then bin="$only"; fi
  fi
  if [ ! -e "$bin" ]; then
    echo "staging: installed, but no runnable binary found under $bindir"
    echo "staged_failed"; return 0
  fi

  local reported
  reported="$(_inv_semver "$("$bin" --version 2>/dev/null | head -3)")"
  if [ -z "$reported" ]; then
    echo "staging: binary present but '$cli --version' produced no parseable version"
    echo "staged_failed"; return 0
  fi
  echo "staging: binary starts; reports version $reported"

  # version match (leading MAJOR.MINOR.PATCH must agree with the candidate)
  local want_mm got_mm
  want_mm="$(printf '%s' "$candidate" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  got_mm="$(printf '%s' "$reported" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  if [ -n "$want_mm" ] && [ -n "$got_mm" ] && [ "$want_mm" != "$got_mm" ]; then
    echo "staging: WARNING — reported version $reported does not match the requested candidate $candidate"
    echo "staged_failed"; return 0
  fi

  # expected subcommands still present
  local ok_subcommands=1 sub
  case "$component" in
    graphify) for sub in query; do "$bin" "$sub" --help >/dev/null 2>&1 || ok_subcommands=0; done ;;
    agent-reach) "$bin" --help 2>&1 | grep -qw doctor || ok_subcommands=0 ;;
  esac
  if [ "$ok_subcommands" -ne 1 ]; then
    echo "staging: a subcommand the stack depends on is missing in the candidate"
    echo "staged_failed"; return 0
  fi

  echo "staging: candidate verified in isolation (binary + version + required subcommands)"
  echo "staged_ok"
}

# stage_result <stage_candidate output> -> the trailing result token
stage_result() { printf '%s' "$1" | tail -1; }
