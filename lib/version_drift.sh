#!/usr/bin/env bash
# P2.15: version/compatibility drift detection. Compares ACTUALLY installed
# versions against versions.yaml's pins. For the two subagent products,
# "actually installed" means the version resolved inside each DSH profile's
# own node_modules (what really runs a call) — not a host `claude`/`codex`
# CLI on PATH, which is a separate, non-authoritative signal, since neither
# subagent Bundle uses a host CLI (see docs/upstream-findings.md P2
# section). Detects and reports only — never auto-updates anything.
# Sourced by bin/agent and scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

_VD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VD_ROOT_DIR="$(cd "$_VD_LIB_DIR/.." && pwd)"

version_drift_pinned() {
  case "$1" in
    dsh) grep -A2 '^deepseek_harness:' "$_VD_ROOT_DIR/versions.yaml" | grep 'tested_version:' | sed -E 's/.*"([^"]+)".*/\1/' ;;
    claude_agent_sdk) grep -A3 '^claude_code:' "$_VD_ROOT_DIR/versions.yaml" | grep 'agent_sdk_version:' | sed -E 's/.*"([^"]+)".*/\1/' ;;
    codex_wrapper) grep -A3 '^codex:' "$_VD_ROOT_DIR/versions.yaml" | grep 'wrapper_version:' | sed -E 's/.*"([^"]+)".*/\1/' ;;
    *) return 1 ;;
  esac
}

# version_drift_compare <installed> <pinned> -> equal|newer|older|unknown
# Exact string match wins outright; otherwise compares the leading
# MAJOR.MINOR.PATCH numeric tuple (ignoring prerelease/build suffixes,
# which this stack's own pins are full of, e.g. "0.1.1-rc.2"). A same-tuple
# but differing full string (a different rc/build) is reported "newer" —
# the conservative "something about this doesn't match what was tested"
# signal, not a claim about ordering.
version_drift_compare() {
  local installed="$1" pinned="$2"
  [ "$installed" = "$pinned" ] && { echo "equal"; return 0; }
  node -e '
    const [a, b] = process.argv.slice(1)
    const parse = (v) => { const m = /^(\d+)\.(\d+)\.(\d+)/.exec(v); return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null }
    const pa = parse(a), pb = parse(b)
    if (!pa || !pb) { console.log("unknown"); process.exit(0) }
    for (let i = 0; i < 3; i++) {
      if (pa[i] > pb[i]) { console.log("newer"); process.exit(0) }
      if (pa[i] < pb[i]) { console.log("older"); process.exit(0) }
    }
    console.log("newer")
  ' "$installed" "$pinned"
}

# version_drift_status <installed> <pinned>
# Prints SUPPORTED | NEWER_UNTESTED | OLDER_UNSUPPORTED | MISSING | UNKNOWN.
version_drift_status() {
  local installed="$1" pinned="$2"
  if [ -z "$installed" ]; then echo "MISSING"; return 0; fi
  case "$(version_drift_compare "$installed" "$pinned")" in
    equal) echo "SUPPORTED" ;;
    newer) echo "NEWER_UNTESTED" ;;
    older) echo "OLDER_UNSUPPORTED" ;;
    *) echo "UNKNOWN" ;;
  esac
}

version_drift_installed_dsh() {
  env_has_cmd dsh && dsh --version 2>/dev/null | tr -d '[:space:]'
  return 0
}

# version_drift_installed_claude_agent_sdk <dsh_home_dir>
# Real feature-probe-adjacent check (P2.15 "upstream feature probes"): reads
# the version actually resolved in the lead profile's own node_modules,
# rather than trusting a version NUMBER we didn't verify was ever installed.
version_drift_installed_claude_agent_sdk() {
  local pkg="$1/profiles/lead/node_modules/@anthropic-ai/claude-agent-sdk/package.json"
  [ -f "$pkg" ] && node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$pkg" 2>/dev/null
  return 0
}

version_drift_installed_codex_wrapper() {
  local pkg="$1/profiles/reviewer/node_modules/@openai/codex/package.json"
  [ -f "$pkg" ] && node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$pkg" 2>/dev/null
  return 0
}
