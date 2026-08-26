#!/usr/bin/env bash
# Idempotent installer. Never uses sudo, never installs system packages
# silently, never logs in on the user's behalf. Distinguishes "installed" /
# "needs install" / "incompatible version" / "login pending" and tells the
# user exactly what to run for anything it cannot safely do itself (P0.12).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/environment.sh
source "$ROOT_DIR/lib/environment.sh"

DSH_VERSION="$(grep -A2 '^deepseek_harness:' "$ROOT_DIR/versions.yaml" | grep 'tested_version:' | sed -E 's/.*"([^"]+)".*/\1/')"

say() { echo "$@"; }
warn() { echo "warning: $*" >&2; }
fail() { echo "error: $*" >&2; exit 1; }

check_node() {
  if ! env_has_cmd node; then
    fail "Node.js not found. Install Node >= 22.19.0 yourself (nvm, your distro's package manager, or https://nodejs.org) and re-run this script. Not doing this automatically because it would need system-level changes."
  fi
  if ! env_node_version_ok; then
    fail "Node $(env_node_version) found, but >= 22.19.0 is required (see versions.yaml). Upgrade Node yourself and re-run."
  fi
  say "Node $(env_node_version): ok"
}

check_pnpm() {
  if env_pnpm_ok; then
    say "pnpm: ok ($(pnpm --version))"
    return 0
  fi
  warn "pnpm not found. 'dsh plugin' needs it on PATH to manage profile bundles."
  say "  Try: corepack enable && corepack prepare pnpm@11.7.0 --activate"
  say "  or:  npm install -g pnpm@11.7.0"
  return 1
}

check_or_install_dsh() {
  if env_dsh_ok; then
    say "dsh: ok ($(dsh --version 2>/dev/null || echo 'version unknown'))"
    return 0
  fi
  say "dsh not found. Attempting: npm install -g @deepseek-ai/dsh@${DSH_VERSION}"
  if npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"; then
    say "dsh installed."
  else
    fail "Could not install dsh automatically. Run this yourself (it may need a writable global npm prefix, not sudo): npm install -g @deepseek-ai/dsh@${DSH_VERSION}"
  fi
}

print_auth_instructions() {
  echo
  echo "== Authentication (not automated — logins are the user's, never ours) =="
  echo "Claude Code (subscription session, not API billing):"
  echo "  1. Install the official CLI if you don't have it: npm install -g @anthropic-ai/claude-code"
  echo "  2. Run: claude"
  echo "     Log in once with your subscription. This login is shared with the"
  echo "     private Claude Code CLI our 'lead' profile bundles internally."
  echo
  echo "Codex (ChatGPT plan, not API billing):"
  echo "  1. Install the official CLI if you don't have it: npm install -g @openai/codex"
  echo "  2. Run: codex login"
  echo "     Log in with your ChatGPT plan. scripts/configure.sh links this"
  echo "     login into the dedicated read-only CODEX_HOME the reviewer uses."
  echo
  echo "DeepSeek (required — this is the model driving the orchestrator itself,"
  echo "unrelated to the two logins above):"
  echo "  Set DEEPSEEK_API_KEY in your environment or in \$DSH_HOME/.env."
}

main() {
  echo "== DeepSeek Harness agent stack: install =="
  check_node
  check_pnpm || true
  check_or_install_dsh
  echo
  echo "Core tools ready. Configuring profiles..."
  "$SCRIPT_DIR/configure.sh"
  print_auth_instructions
  echo
  echo "Next: agent doctor"
}

main "$@"
