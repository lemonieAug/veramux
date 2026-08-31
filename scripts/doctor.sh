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
# shellcheck source=../lib/project_detect.sh
source "$ROOT_DIR/lib/project_detect.sh"
# shellcheck source=../lib/graph.sh
source "$ROOT_DIR/lib/graph.sh"
# shellcheck source=../lib/memory.sh
source "$ROOT_DIR/lib/memory.sh"
# shellcheck source=../lib/risk.sh
source "$ROOT_DIR/lib/risk.sh"
# shellcheck source=../lib/run_lifecycle.sh
source "$ROOT_DIR/lib/run_lifecycle.sh"
# shellcheck source=../lib/state_paths.sh
source "$ROOT_DIR/lib/state_paths.sh"
# shellcheck source=../lib/version_drift.sh
source "$ROOT_DIR/lib/version_drift.sh"
# shellcheck source=../lib/compat.sh
source "$ROOT_DIR/lib/compat.sh"
# shellcheck source=../lib/capability_probe.sh
source "$ROOT_DIR/lib/capability_probe.sh"
# shellcheck source=../lib/inventory.sh
source "$ROOT_DIR/lib/inventory.sh"
# shellcheck source=../lib/profiles.sh
source "$ROOT_DIR/lib/profiles.sh"

DSH_HOME_DIR="$(env_dsh_home)"
FAILURES=0
CRITICAL_FAILURES=0

ok()   { printf '  \xe2\x9c\x93 %s\n' "$*"; }
bad()  { printf '  \xc3\x97 %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
crit() { printf '  \xc3\x97 %s [blocking]\n' "$*"; FAILURES=$((FAILURES + 1)); CRITICAL_FAILURES=$((CRITICAL_FAILURES + 1)); }
warn() { printf '  ! %s [degraded]\n' "$*"; FAILURES=$((FAILURES + 1)); }
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
if env_orchestrator_deepseek_configured "$DSH_HOME_DIR/.env" && env_orchestrator_openai_configured "$DSH_HOME_DIR/.env"; then
  ok "relay providers: DeepSeek primary ($(env_orchestrator_deepseek_model "$DSH_HOME_DIR/.env")); OpenAI fallback ($(env_orchestrator_openai_model "$DSH_HOME_DIR/.env")); credentials present (values hidden)"
elif env_orchestrator_deepseek_configured "$DSH_HOME_DIR/.env"; then
  ok "relay provider: DeepSeek primary ($(env_orchestrator_deepseek_model "$DSH_HOME_DIR/.env")); OpenAI fallback is not configured"
elif env_orchestrator_openai_configured "$DSH_HOME_DIR/.env"; then
  warn "DeepSeek primary is not configured; OpenAI ($(env_orchestrator_openai_model "$DSH_HOME_DIR/.env")) is available as the degraded relay provider"
else
  crit "no relay credential is configured; set VERAMUX_DEEPSEEK_API_KEY and optionally VERAMUX_OPENAI_API_KEY"
fi
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

section "Run storage (P2.5)"
STATE_DIR="$(state_root_dir)"
if mkdir -p "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ]; then
  ok "state directory writable: $STATE_DIR"
else
  bad "state directory not writable: $STATE_DIR"
fi
RUNS_ROOT="$(state_runs_root_dir)"
CORRUPT_COUNT=0
if [ -d "$RUNS_ROOT" ]; then
  while IFS= read -r -d '' rj; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$rj" >/dev/null 2>&1 || CORRUPT_COUNT=$((CORRUPT_COUNT + 1))
  done < <(find "$RUNS_ROOT" -name run.json -print0 2>/dev/null)
fi
if [ "$CORRUPT_COUNT" -eq 0 ]; then
  ok "no corrupt run journal detected"
else
  bad "$CORRUPT_COUNT corrupt run.json file(s) detected under $RUNS_ROOT"
fi
ok "run journal schema_version 1 supported"

section "Locks (P2.12)"
LOCKS_DIR="$(state_locks_dir)"
STALE_LOCK_COUNT=0
if [ -d "$LOCKS_DIR" ]; then
  HERE_HOST="$(hostname 2>/dev/null || echo unknown)"
  while IFS= read -r -d '' lockdir; do
    infofile="$lockdir/info"
    [ -f "$infofile" ] || continue
    l_run="" l_pid="" l_host="" l_created=""
    IFS=$'\t' read -r l_run l_pid l_host l_created < "$infofile"
    if [ "$l_host" = "$HERE_HOST" ] && ! kill -0 "$l_pid" 2>/dev/null; then
      STALE_LOCK_COUNT=$((STALE_LOCK_COUNT + 1))
    fi
  done < <(find "$LOCKS_DIR" -maxdepth 1 -type d -name '*.lock.d' -print0 2>/dev/null)
fi
if [ "$STALE_LOCK_COUNT" -eq 0 ]; then
  ok "no stale lock detected"
else
  bad "$STALE_LOCK_COUNT stale lock(s) detected — run 'agent unlock <path>' for the affected project"
fi

section "Versions (P2.15 — detect drift, never auto-update)"
DSH_INSTALLED="$(version_drift_installed_dsh)"
DSH_PINNED="$(version_drift_pinned dsh)"
case "$(version_drift_status "$DSH_INSTALLED" "$DSH_PINNED")" in
  SUPPORTED) ok "dsh: installed $DSH_INSTALLED matches the tested pin" ;;
  MISSING) info "dsh: not installed — cannot check version drift" ;;
  NEWER_UNTESTED) bad "dsh: installed $DSH_INSTALLED is NEWER than the tested pin $DSH_PINNED — re-run discovery (docs/upstream-findings.md) before relying on it" ;;
  OLDER_UNSUPPORTED) bad "dsh: installed $DSH_INSTALLED is OLDER than the tested pin $DSH_PINNED — upgrade recommended" ;;
  *) info "dsh: could not compare versions ($DSH_INSTALLED vs $DSH_PINNED)" ;;
esac

SDK_INSTALLED="$(version_drift_installed_claude_agent_sdk "$DSH_HOME_DIR")"
if [ -n "$SDK_INSTALLED" ]; then
  SDK_PINNED="$(version_drift_pinned claude_agent_sdk)"
  case "$(version_drift_status "$SDK_INSTALLED" "$SDK_PINNED")" in
    SUPPORTED) ok "Claude Agent SDK (bundled in lead profile): $SDK_INSTALLED matches the tested pin" ;;
    NEWER_UNTESTED) bad "Claude Agent SDK: bundled $SDK_INSTALLED is NEWER than the tested pin $SDK_PINNED" ;;
    OLDER_UNSUPPORTED) bad "Claude Agent SDK: bundled $SDK_INSTALLED is OLDER than the tested pin $SDK_PINNED" ;;
    *) info "Claude Agent SDK: could not compare versions" ;;
  esac
else
  info "Claude Agent SDK: lead profile not installed yet — cannot check bundled version"
fi

CODEX_WRAPPER_INSTALLED="$(version_drift_installed_codex_wrapper "$DSH_HOME_DIR")"
if [ -n "$CODEX_WRAPPER_INSTALLED" ]; then
  CODEX_WRAPPER_PINNED="$(version_drift_pinned codex_wrapper)"
  case "$(version_drift_status "$CODEX_WRAPPER_INSTALLED" "$CODEX_WRAPPER_PINNED")" in
    SUPPORTED) ok "Codex wrapper (bundled in reviewer profile): $CODEX_WRAPPER_INSTALLED matches the tested pin" ;;
    NEWER_UNTESTED) bad "Codex wrapper: bundled $CODEX_WRAPPER_INSTALLED is NEWER than the tested pin $CODEX_WRAPPER_PINNED" ;;
    OLDER_UNSUPPORTED) bad "Codex wrapper: bundled $CODEX_WRAPPER_INSTALLED is OLDER than the tested pin $CODEX_WRAPPER_PINNED" ;;
    *) info "Codex wrapper: could not compare versions" ;;
  esac
else
  info "Codex wrapper: reviewer profile not installed yet — cannot check bundled version"
fi
info "host 'claude'/'codex' CLIs on PATH (checked above) are a separate, non-authoritative signal — see docs/upstream-findings.md (each Bundle uses its own pinned payload, not a host CLI)"
info "auto_update is always off (policies/runtime.yaml versions.auto_update: false) — this stack only detects and reports drift"

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
    ECOSYSTEM="$( { project_detect_ecosystem "$RESOLVED"; project_detect_ecosystems_extended "$RESOLVED"; } | tr '\n' ' ')"
    if [ -n "$(echo "$ECOSYSTEM" | tr -d '[:space:]')" ]; then
      ok "ecosystem detected: $ECOSYSTEM"
    else
      info "no known ecosystem detected — validation will be empty"
    fi
    if [ -f "$RESOLVED/package.json" ]; then
      PM_ERR="$(mktemp)"
      PM="$(project_pm_resolve "$RESOLVED" 2>"$PM_ERR")" || true
      if [ -s "$PM_ERR" ]; then
        bad "$(cat "$PM_ERR")"
      elif [ -n "$PM" ]; then
        ok "package manager: $PM"
      fi
      rm -f "$PM_ERR"
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

section "Maintenance (P3)"
info "active optimization profile: $(profile_active 2>/dev/null || echo balanced)"
_incompat=0
while IFS= read -r _c; do
  [ -n "$_c" ] || continue
  _v="$(inventory_detect_version "$_c" 2>/dev/null)"
  [ -n "$_v" ] || continue
  if [ "$(capability_verdict "$_c" 2>/dev/null)" = "INCOMPATIBLE" ]; then
    bad "$_c: a required capability probes INCOMPATIBLE — run 'agent inventory' and 'agent update plan $_c'"
    _incompat=1
  fi
done < <(compat_components 2>/dev/null)
[ "$_incompat" -eq 0 ] && ok "no component reports an INCOMPATIBLE capability"
_snap_root="$(state_snapshots_dir 2>/dev/null)"
if [ -d "$_snap_root" ]; then
  _snaps="$(find "$_snap_root" -maxdepth 1 -type d -name 'snap-*' 2>/dev/null | wc -l | tr -d ' ')"
  info "$_snaps pre-update snapshot(s) retained ($_snap_root)"
fi
info "'agent update check' shows what has a newer version (deterministic, no LLM, no changes)"

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
