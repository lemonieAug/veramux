#!/usr/bin/env bash
# `agent doctor [path]` — P0.11. Never prints secret values. Exits nonzero
# on any impeditive failure (missing core tool, reviewer not read-only,
# hardcoded credential in our own profile config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/environment.sh
source "$ROOT_DIR/lib/environment.sh"
# shellcheck source=../lib/policy.sh
source "$ROOT_DIR/lib/policy.sh"
# shellcheck source=../lib/project.sh
source "$ROOT_DIR/lib/project.sh"
# shellcheck source=../lib/project_config.sh
source "$ROOT_DIR/lib/project_config.sh"
# shellcheck source=../lib/validation.sh
source "$ROOT_DIR/lib/validation.sh"
# shellcheck source=../lib/graph.sh
source "$ROOT_DIR/lib/graph.sh"
# shellcheck source=../lib/memory.sh
source "$ROOT_DIR/lib/memory.sh"
# shellcheck source=../lib/risk.sh
source "$ROOT_DIR/lib/risk.sh"

DSH_HOME_DIR="$(env_dsh_home)"
FAILURES=0
CRITICAL_FAILURES=0

ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
bad()  { printf '  \xc3\x97 %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
crit() { printf '  \xc3\x97 %s [blocking]\n' "$*"; FAILURES=$((FAILURES + 1)); CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1)); }
info() { echo "  - $*"; }

section() { echo; echo "$1"; }

# True if `- id: <id>` is immediately followed by `disabled: true` in a
# cordis.patch.yml-style file (the only shape our own templates use for
# these disable rows — see harness/profiles/*/cordis.patch.yml).
patch_row_disabled() {
  local file="$1" id="$2"
  awk -v id="$id" '
    $0 ~ ("- id: " id "$") { found=1; next }
    found { print; exit }
  ' "$file" | grep -q 'disabled: true'
}

section "Core"
if env_has_cmd git; then ok "git ($(git --version | awk '{print $3}'))"; else crit "git not found"; fi
if env_has_cmd node && env_node_version_ok; then ok "Node ($(env_node_version))"; elif env_has_cmd node; then bad "Node $(env_node_version) found, but >= 22.19.0 required"; else crit "Node not found"; fi
if env_has_cmd pnpm; then ok "pnpm ($(pnpm --version))"; else bad "pnpm not found (needed by 'dsh plugin')"; fi
if env_dsh_ok; then ok "DeepSeek Harness (dsh $(dsh --version 2>/dev/null || echo '?'))"; else crit "dsh not found — run scripts/install.sh"; fi

section "Claude"
if env_has_cmd claude; then
  ok "claude CLI present on PATH ($(claude --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  info "no host 'claude' CLI on PATH — not required (the lead profile's Claude Agent SDK bundles its own), but you need it to run 'claude' once and log in"
fi
if [ -f "$HOME/.claude.json" ] || [ -d "$HOME/.claude" ]; then
  ok "found local Claude Code config/credential state (heuristic only — cannot confirm subscription vs API key from here)"
else
  bad "no Claude Code config found at ~/.claude(.json) — run 'claude' once and log in before using the lead profile"
fi

section "Codex"
if env_has_cmd codex; then
  ok "codex CLI present on PATH ($(codex --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  info "no host 'codex' CLI on PATH — not required (the reviewer profile bundles its own wrapper), but you need it to run 'codex login'"
fi
if [ -f "$HOME/.codex/auth.json" ]; then
  ok "found ~/.codex/auth.json (heuristic only — cannot confirm ChatGPT-plan vs API-key login from here)"
else
  bad "no ~/.codex/auth.json found — run 'codex login' before using the reviewer profile"
fi

section "Harness profiles"
LEAD_PKG="$DSH_HOME_DIR/profiles/lead/package.json"
REVIEWER_PKG="$DSH_HOME_DIR/profiles/reviewer/package.json"
if [ -f "$LEAD_PKG" ]; then ok "lead profile exists ($LEAD_PKG)"; else bad "lead profile missing — run scripts/configure.sh"; fi
if env_profile_has_bundle "$LEAD_PKG" '@deepseek-ai/dsh-subagent-claude-code'; then
  ok "lead profile has the Claude Code subagent bundle"
else
  bad "lead profile is missing @deepseek-ai/dsh-subagent-claude-code"
fi
if [ -f "$REVIEWER_PKG" ]; then ok "reviewer profile exists ($REVIEWER_PKG)"; else bad "reviewer profile missing — run scripts/configure.sh"; fi
if env_profile_has_bundle "$REVIEWER_PKG" '@deepseek-ai/dsh-subagent-codex'; then
  ok "reviewer profile has the Codex subagent bundle"
else
  bad "reviewer profile is missing @deepseek-ai/dsh-subagent-codex"
fi

REVIEWER_PATCH="$DSH_HOME_DIR/profiles/reviewer/cordis.patch.yml"
if [ -f "$REVIEWER_PATCH" ]; then
  if grep -q 'toolName: subagent_codex' "$REVIEWER_PATCH" \
    && patch_row_disabled "$REVIEWER_PATCH" tool-fs \
    && patch_row_disabled "$REVIEWER_PATCH" tool-bash \
    && patch_row_disabled "$REVIEWER_PATCH" tool-str-replace-editor; then
    ok "reviewer profile disables native write/edit/shell tool rows (mechanism-level read-only)"
  else
    crit "reviewer profile does not clearly disable native write/edit/shell tools — read-only is not enforced"
  fi
  if grep -qE 'CODEX_HOME:' "$REVIEWER_PATCH"; then
    ok "reviewer profile pins a dedicated CODEX_HOME"
  else
    bad "reviewer profile has no dedicated CODEX_HOME override"
  fi
  CODEX_HOME_DIR="$DSH_HOME_DIR/profiles/reviewer/codex-home"
  if [ -f "$CODEX_HOME_DIR/config.toml" ] && grep -q 'sandbox_mode = "read-only"' "$CODEX_HOME_DIR/config.toml"; then
    ok "reviewer CODEX_HOME pins sandbox_mode = read-only"
  else
    crit "reviewer CODEX_HOME missing or does not pin sandbox_mode = read-only"
  fi
else
  bad "reviewer profile cordis.patch.yml missing — run scripts/configure.sh"
fi

section "Safety"
if env_report_billing_risk_vars; then
  ok "no ANTHROPIC_API_KEY/OPENAI_API_KEY in this shell's environment"
else
  info "see WARNING/ERROR lines above about ambient credential-shaped env vars"
fi
if env_scan_profiles_for_hardcoded_keys "$DSH_HOME_DIR/profiles" 2>&1; then
  ok "no hardcoded ANTHROPIC_API_KEY/OPENAI_API_KEY in installed profile configs"
else
  if env_safety_allows_key_override "$ROOT_DIR/policies/safety.yaml"; then
    bad "a profile config forwards a credential, but policies/safety.yaml explicitly allows it"
  else
    crit "a profile config forwards ANTHROPIC_API_KEY/OPENAI_API_KEY — see message above"
  fi
fi

section "Context (P1 — all optional, never required for P0 behavior)"
if graph_available; then
  ok "Graphify installed ($(graphify --version 2>/dev/null || echo 'version unknown'))"
else
  info "Graphify not installed — optional. See README 'Context tools' for the install command."
fi
if [ -f "$HOME/.claude-mem/settings.json" ] || [ -d "$HOME/.claude/plugins/marketplaces/thedotmack" ]; then
  ok "claude-mem installed"
  if memory_available; then
    ok "claude-mem worker responding on $(memory_worker_url)"
  else
    bad "claude-mem installed but its worker is not responding on $(memory_worker_url) — it should auto-start on the next Claude Code session"
  fi
else
  info "claude-mem not installed — optional. See README 'Context tools' for the install command."
fi

section "Research (P1 — all optional)"
if env_has_cmd curl; then
  ok "curl present (needed for the built-in web/search research path)"
else
  bad "curl not found — external research (web fetch/search) will be unavailable"
fi
if env_has_cmd gh; then
  ok "gh CLI present ($(gh --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  info "gh CLI not installed — optional, only used for GitHub-specific research"
fi
if env_has_cmd agent-reach; then
  ok "Agent-Reach installed — run 'agent-reach doctor' yourself for per-channel status"
else
  info "Agent-Reach not installed — optional; the built-in web/search/GitHub research path works without it. See README."
fi

section "Policy (P1)"
for policy_file in orchestration.yaml risk.yaml context.yaml safety.yaml review.yaml; do
  if [ -f "$ROOT_DIR/policies/$policy_file" ]; then
    ok "policies/$policy_file present"
  else
    crit "policies/$policy_file missing"
  fi
done
if grep -q '^max_correction_rounds:' "$ROOT_DIR/policies/orchestration.yaml" 2>/dev/null; then
  ok "orchestration.yaml parses (max_correction_rounds found)"
else
  crit "orchestration.yaml missing max_correction_rounds"
fi

PROJECT_PATH="${1:-}"
if [ -n "$PROJECT_PATH" ]; then
  section "Project ($PROJECT_PATH)"
  if RESOLVED="$(project_resolve_workspace "$PROJECT_PATH" 2>&1)"; then
    ok "path resolves: $RESOLVED"
    if project_is_git_repo "$RESOLVED"; then
      ok "git repository"
    else
      bad "not a git repository — git diff/status based review will not work"
    fi
    ECOSYSTEM="$(project_detect_ecosystem "$RESOLVED" | tr '\n' ' ')"
    if [ -n "$(echo "$ECOSYSTEM" | tr -d '[:space:]')" ]; then
      ok "ecosystem detected: $ECOSYSTEM"
    else
      info "no known ecosystem detected (node/python/make) — validation will be empty"
    fi
    COMMANDS="$(validation_detect_commands "$RESOLVED" false || true)"
    if [ -n "$COMMANDS" ]; then
      ok "validation commands detected:"
      echo "$COMMANDS" | while IFS=$'\t' read -r label cmd; do info "$label: $cmd"; done
    else
      info "no validation commands detected"
    fi
    if project_config_exists "$RESOLVED"; then
      ok "project override found: $(project_config_path "$RESOLVED")"
    else
      info "no .agent/config.yaml — using built-in defaults"
    fi
    if graph_available; then
      if graph_is_ready "$RESOLVED"; then
        ok "knowledge graph available for this project"
      else
        info "Graphify is installed but no graph exists yet for this project — built automatically on first use"
      fi
    fi
  else
    crit "$RESOLVED"
  fi
fi

echo
if [ "$CRITICAL_FAILURES" -gt 0 ]; then
  echo "doctor: $FAILURES issue(s) found, $CRITICAL_FAILURES blocking."
  exit 2
elif [ "$FAILURES" -gt 0 ]; then
  echo "doctor: $FAILURES issue(s) found, none blocking."
  exit 1
else
  echo "doctor: all checks passed."
  exit 0
fi
