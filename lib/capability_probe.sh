#!/usr/bin/env bash
# P3.3 (capability-based compatibility): probe whether a component still
# provides the capabilities the stack depends on. A version number tells you
# how much RISK an update carries; a capability probe tells you whether it
# actually still WORKS. Every probe here is deterministic — a file check, a
# `--help` grep, an HTTP HEAD — never an LLM call and never a call that
# spends Claude/Codex quota.
#
# A probe returns one of:
#   pass            the capability is present and verifiable right now
#   fail            the capability is verifiably ABSENT (this is the only
#                   verdict that makes a component INCOMPATIBLE)
#   unknown         cannot verify without the real component installed, or
#                   without a live provider call — NOT the same as "fine"
#
# Output shape (one line): "<status>\t<reason>". Sourced by bin/agent and
# scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_CAPPROBE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_capprobe_emit() { printf '%s\t%s\n' "$1" "$2"; }

# _capprobe_patch_row_disabled <cordis.patch.yml> <row-id>
# Mirrors scripts/doctor.sh's own check: the row appears and is set false.
_capprobe_patch_row_disabled() {
  local file="$1" row="$2"
  [ -f "$file" ] || return 1
  awk -v row="$row" '
    $0 ~ ("id:[[:space:]]*\"?" row "\"?") { found=1 }
    found && /enabled:[[:space:]]*false/ { print "yes"; exit }
    found && /^[[:space:]]*-[[:space:]]*id:/ && $0 !~ row { found=0 }
  ' "$file" 2>/dev/null | grep -q yes
}

# capability_probe <component> <capability> -> "<status>\t<reason>"
capability_probe() {
  local component="$1" cap="$2" dsh_home
  dsh_home="$(env_dsh_home)"
  local lead_pkg="$dsh_home/profiles/lead/package.json"
  local reviewer_pkg="$dsh_home/profiles/reviewer/package.json"
  local reviewer_patch="$dsh_home/profiles/reviewer/cordis.patch.yml"
  local codex_home_cfg="$dsh_home/profiles/reviewer/codex-home/config.toml"

  case "$component/$cap" in
    deepseek-harness/claude-code-subagent)
      if [ ! -f "$lead_pkg" ]; then _capprobe_emit unknown "lead profile not installed"; return 0; fi
      if env_profile_has_bundle "$lead_pkg" '@deepseek-ai/dsh-subagent-claude-code'; then
        _capprobe_emit pass "lead profile declares the Claude Code subagent bundle"
      else
        _capprobe_emit fail "lead profile no longer declares @deepseek-ai/dsh-subagent-claude-code"
      fi ;;

    deepseek-harness/codex-subagent|codex/reviewer-session-starts)
      if [ ! -f "$reviewer_pkg" ]; then _capprobe_emit unknown "reviewer profile not installed"; return 0; fi
      if env_profile_has_bundle "$reviewer_pkg" '@deepseek-ai/dsh-subagent-codex'; then
        _capprobe_emit pass "reviewer profile declares the Codex subagent bundle"
      else
        _capprobe_emit fail "reviewer profile no longer declares @deepseek-ai/dsh-subagent-codex"
      fi ;;

    deepseek-harness/reviewer-read-only|codex/reviewer-read-only-patch-policy)
      if [ ! -f "$reviewer_patch" ]; then _capprobe_emit unknown "reviewer cordis.patch.yml not installed"; return 0; fi
      if _capprobe_patch_row_disabled "$reviewer_patch" tool-fs \
        && _capprobe_patch_row_disabled "$reviewer_patch" tool-bash \
        && _capprobe_patch_row_disabled "$reviewer_patch" tool-str-replace-editor; then
        if [ -f "$codex_home_cfg" ] && grep -q 'sandbox_mode = "read-only"' "$codex_home_cfg"; then
          _capprobe_emit pass "reviewer disables write/edit/shell rows AND pins sandbox_mode=read-only"
        else
          _capprobe_emit fail "reviewer patch rows disabled but CODEX_HOME does not pin sandbox_mode=read-only"
        fi
      else
        _capprobe_emit fail "reviewer profile does not disable native write/edit/shell tool rows"
      fi ;;

    deepseek-harness/code-mode)
      if ! env_has_cmd dsh; then _capprobe_emit unknown "dsh not installed"; return 0; fi
      if dsh --help 2>&1 | grep -qiE 'code[ -]mode'; then
        _capprobe_emit pass "dsh --help advertises Code Mode"
      else
        _capprobe_emit fail "dsh --help no longer advertises Code Mode"
      fi ;;

    deepseek-harness/cwd-propagation)
      _capprobe_emit unknown "only verifiable by a live run (tests/integration or benchmark --live)" ;;

    claude-code/lead-session-starts)
      _capprobe_emit unknown "only verifiable by a live lead call (benchmark --live)" ;;

    claude-code/native-settings-authoritative)
      if [ ! -f "$lead_pkg" ]; then _capprobe_emit unknown "lead profile not installed"; return 0; fi
      local lead_patch="$dsh_home/profiles/lead/cordis.patch.yml"
      if [ -f "$lead_patch" ] && grep -qi 'settingSources' "$lead_patch" 2>/dev/null; then
        _capprobe_emit fail "lead profile overrides settingSources — native settings would no longer be authoritative"
      else
        _capprobe_emit pass "lead profile does not override settingSources"
      fi ;;

    claude-mem/worker-health)
      if ! command -v claude-mem >/dev/null 2>&1; then _capprobe_emit unknown "claude-mem not installed"; return 0; fi
      local cm_settings="$HOME/.claude-mem/settings.json" port url
      # Path is passed as argv, never interpolated into the -e string: a
      # leading-slash literal there is mangled by MSYS path conversion.
      port="$(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(s.workerPort||s.port||3777))}catch{process.stdout.write("3777")}' "$cm_settings" 2>/dev/null)"
      url="http://127.0.0.1:${port}"
      if curl -fsS -m 3 -o /dev/null "$url" 2>/dev/null || curl -fsS -m 3 -o /dev/null "${url}/health" 2>/dev/null; then
        _capprobe_emit pass "claude-mem worker responds on $url"
      else
        _capprobe_emit unknown "claude-mem worker not responding on $url — it auto-starts on the next Claude Code session"
      fi ;;

    claude-mem/mcp-search-tools|claude-mem/session-start-injection)
      if ! command -v claude-mem >/dev/null 2>&1; then _capprobe_emit unknown "claude-mem not installed"; return 0; fi
      local cm_settings="$HOME/.claude-mem/settings.json"
      if [ -f "$cm_settings" ]; then
        if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$cm_settings" 2>/dev/null; then
          _capprobe_emit pass "claude-mem installed and settings.json parses"
        else
          _capprobe_emit fail "~/.claude-mem/settings.json does not parse"
        fi
      else
        _capprobe_emit unknown "claude-mem installed but not yet initialised (no settings.json)"
      fi ;;

    graphify/query-subcommand)
      if ! env_has_cmd graphify; then _capprobe_emit unknown "graphify not installed"; return 0; fi
      if graphify query --help >/dev/null 2>&1; then
        _capprobe_emit pass "graphify query subcommand present"
      else
        _capprobe_emit fail "graphify no longer exposes the 'query' subcommand"
      fi ;;

    graphify/skill-installed-where-expected)
      if ! command -v graphify >/dev/null 2>&1; then _capprobe_emit unknown "graphify not installed"; return 0; fi
      local s
      for s in "$HOME/.claude/skills/graphify/SKILL.md" "$PWD/.claude/skills/graphify/SKILL.md"; do
        [ -f "$s" ] && { _capprobe_emit pass "graphify SKILL.md found at $s"; return 0; }
      done
      _capprobe_emit fail "graphify installed but no SKILL.md at ~/.claude/skills/graphify/ or ./.claude/skills/graphify/" ;;

    agent-reach/doctor-command)
      if ! command -v agent-reach >/dev/null 2>&1; then _capprobe_emit unknown "agent-reach not installed"; return 0; fi
      if agent-reach --help 2>&1 | grep -qw doctor; then
        _capprobe_emit pass "agent-reach exposes a doctor command"
      else
        _capprobe_emit fail "agent-reach --help no longer lists a doctor command"
      fi ;;

    agent-reach/skill-present)
      if ! command -v agent-reach >/dev/null 2>&1; then _capprobe_emit unknown "agent-reach not installed"; return 0; fi
      local a
      for a in "$HOME/.claude/skills/agent-reach/SKILL.md" "$PWD/.claude/skills/agent-reach/SKILL.md"; do
        [ -f "$a" ] && { _capprobe_emit pass "agent-reach SKILL.md found at $a"; return 0; }
      done
      _capprobe_emit fail "agent-reach installed but no SKILL.md found" ;;

    *)
      _capprobe_emit unknown "no probe defined for $component/$cap" ;;
  esac
}

# capability_probe_component <component>
# Runs every required capability from compat.yaml. Prints one
# "<capability>\t<status>\t<reason>" line each. Return code:
#   0  no capability FAILED (some may be unknown)
#   1  at least one capability FAILED  -> component is INCOMPATIBLE
capability_probe_component() {
  local component="$1" cap status reason any_fail=0 out
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    out="$(capability_probe "$component" "$cap")"
    status="${out%%$'\t'*}"
    reason="${out#*$'\t'}"
    printf '%s\t%s\t%s\n' "$cap" "$status" "$reason"
    [ "$status" = "fail" ] && any_fail=1
  done < <(compat_required_capabilities "$component")
  return "$any_fail"
}

# capability_verdict <component> -> OK | INCOMPATIBLE | UNVERIFIED
#   OK           every required capability probed pass
#   INCOMPATIBLE at least one probed fail
#   UNVERIFIED   no failures, but at least one capability could not be
#                verified (component not installed, or needs a live call)
capability_verdict() {
  local component="$1" cap status reason had_unknown=0 had_fail=0 had_any=0 out
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    had_any=1
    out="$(capability_probe "$component" "$cap")"
    status="${out%%$'\t'*}"
    case "$status" in
      fail) had_fail=1 ;;
      unknown) had_unknown=1 ;;
    esac
  done < <(compat_required_capabilities "$component")
  if [ "$had_fail" -eq 1 ]; then echo "INCOMPATIBLE"; return 0; fi
  if [ "$had_any" -eq 0 ]; then echo "OK"; return 0; fi
  if [ "$had_unknown" -eq 1 ]; then echo "UNVERIFIED"; return 0; fi
  echo "OK"
}
