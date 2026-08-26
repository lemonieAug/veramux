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

# P1 context tools are optional and never auto-installed here: Graphify and
# claude-mem pull in real new runtime dependencies (Python/uv, Bun) and, for
# claude-mem, a global Claude Code plugin install — a bigger footprint than
# P0's own dependencies, so it gets the same treatment as Claude/Codex login:
# print the exact command, let the user decide. Once installed, lib/graph.sh
# and lib/memory.sh detect and use them automatically — no further setup.
print_context_tool_instructions() {
  echo
  echo "== Optional P1 context tools (not installed automatically) =="
  if env_has_cmd graphify; then
    say "Graphify: already installed ($(graphify --version 2>/dev/null || echo 'version unknown'))."
  else
    echo "Graphify (code structure graph, fully local for code — no API key needed):"
    echo "  uv tool install graphifyy   # or: pipx install graphifyy"
    echo "  (nothing else to do — 'agent' registers and builds the graph per"
    echo "   project automatically the first time it's useful)"
  fi
  echo
  if [ -f "$HOME/.claude-mem/settings.json" ] || [ -d "$HOME/.claude/plugins/marketplaces/thedotmack" ]; then
    say "claude-mem: already installed."
  else
    echo "claude-mem (persistent memory across sessions, subscription-based"
    echo "compression by default, not API billing):"
    echo "  npx claude-mem install"
    echo "  (needs Node >= 20.12, and installs Bun + uv itself if missing —"
    echo "   review its prompts before continuing)"
  fi
  echo
  if env_has_cmd agent-reach; then
    say "Agent-Reach: already installed."
  else
    echo "Agent-Reach (external research, optional): the built-in web/search/"
    echo "GitHub research path (lib/research.sh) works without it. If you want"
    echo "the fuller channel set (YouTube, RSS, and more), see:"
    echo "  https://github.com/Panniantong/Agent-Reach"
    echo "  We do not run its installer for you — it is designed to be run by"
    echo "  telling an agent to fetch and follow its own install.md, which is"
    echo "  a deliberate choice you should make yourself, not something this"
    echo "  script does on your behalf."
  fi
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
  print_context_tool_instructions
  echo
  echo "Next: agent doctor"
}

main "$@"
