#!/usr/bin/env bash
# Idempotent: (re)creates the `lead` and `reviewer` DSH profiles from the
# templates under harness/profiles/, using the official `dsh plugin` command
# to manage bundles (we never hand-author a profile's package.json/bundles
# list — see docs/upstream-findings.md). Safe to re-run any time, including
# after `versions.yaml` changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/environment.sh
source "$ROOT_DIR/lib/environment.sh"

DSH_HOME_DIR="$(env_dsh_home)"

require_dsh() {
  if ! env_dsh_ok; then
    echo "error: 'dsh' not found on PATH. Run scripts/install.sh first." >&2
    exit 1
  fi
}

setup_lead_profile() {
  echo "== configuring profile: lead =="
  dsh plugin --profile lead add '@deepseek-ai/dsh-headless' '@deepseek-ai/dsh-subagent-claude-code'

  local profile_dir="$DSH_HOME_DIR/profiles/lead"
  mkdir -p "$profile_dir"
  cp "$ROOT_DIR/harness/profiles/lead/cordis.patch.yml" "$profile_dir/cordis.patch.yml"
  echo "== lead profile ready at $profile_dir =="
}

setup_reviewer_profile() {
  echo "== configuring profile: reviewer =="
  dsh plugin --profile reviewer add '@deepseek-ai/dsh-headless' '@deepseek-ai/dsh-subagent-codex'

  local profile_dir="$DSH_HOME_DIR/profiles/reviewer"
  local codex_home="$profile_dir/codex-home"
  mkdir -p "$codex_home"
  cp "$ROOT_DIR/harness/config/codex-reviewer-home/config.toml" "$codex_home/config.toml"

  local real_auth="$HOME/.codex/auth.json"
  if [ -f "$real_auth" ]; then
    ln -sf "$real_auth" "$codex_home/auth.json" 2>/dev/null || cp "$real_auth" "$codex_home/auth.json"
    echo "linked Codex auth from $real_auth into the dedicated reviewer CODEX_HOME"
  else
    echo "warning: $real_auth not found yet — run 'codex login' before using the reviewer." >&2
  fi

  local escaped_codex_home
  escaped_codex_home="$(printf '%s' "$codex_home" | sed -e 's/[\&]/\\&/g')"
  sed "s#__CODEX_REVIEWER_HOME__#${escaped_codex_home}#" \
    "$ROOT_DIR/harness/profiles/reviewer/cordis.patch.yml" > "$profile_dir/cordis.patch.yml"
  echo "== reviewer profile ready at $profile_dir =="
}

main() {
  require_dsh
  setup_lead_profile
  setup_reviewer_profile
  echo
  echo "Done. Verify with: agent doctor"
}

main "$@"
