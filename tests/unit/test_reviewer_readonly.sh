#!/usr/bin/env bash
# Static checks on our own shipped config: the reviewer profile must disable
# every native write/edit/shell tool row and pin a read-only Codex sandbox.
# This is the "policy/tool permissions, not just prompt" enforcement from
# P0.5/P0.10 — see docs/upstream-findings.md for why this is the real
# control point given what DeepSeek Harness provides.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"

PATCH="$ROOT_DIR/harness/profiles/reviewer/cordis.patch.yml"
CONFIG_TOML="$ROOT_DIR/harness/config/codex-reviewer-home/config.toml"

patch_row_disabled() {
  local id="$1"
  awk -v id="$id" '
    $0 ~ ("- id: " id "$") { found=1; next }
    found { print; exit }
  ' "$PATCH" | grep -q 'disabled: true'
}

for id in tool-bash tool-pwsh tool-fs tool-fs-search tool-str-replace-editor tool-web tool-jobs \
          tool-subagent tool-subagent-fork tool-subagent-control tool-subagent-list-agents \
          tool-workflow tool-todo tool-skill tool-goal tool-ralph; do
  if patch_row_disabled "$id"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: reviewer profile does not disable native tool row: $id" >&2
  fi
done

assert_contains "$(cat "$PATCH")" "toolName: subagent_codex" "reviewer profile exposes the subagent_codex tool"
assert_contains "$(cat "$PATCH")" "CODEX_HOME:" "reviewer profile pins a dedicated CODEX_HOME"
assert_contains "$(cat "$PATCH")" "mode: read-only" "reviewer profile's own sandbox-policy is read-only too (defense in depth)"

assert_contains "$(cat "$CONFIG_TOML")" 'sandbox_mode = "read-only"' "dedicated Codex sandbox is read-only"

# The lead profile must NOT have a native bash/fs/editor path either — all
# implementation work is meant to happen inside Claude Code's own session.
LEAD_PATCH="$ROOT_DIR/harness/profiles/lead/cordis.patch.yml"
patch_row_disabled_in() {
  local file="$1" id="$2"
  awk -v id="$id" '
    $0 ~ ("- id: " id "$") { found=1; next }
    found { print; exit }
  ' "$file" | grep -q 'disabled: true'
}
for id in tool-bash tool-fs tool-str-replace-editor; do
  if patch_row_disabled_in "$LEAD_PATCH" "$id"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL: lead profile does not disable native tool row: $id" >&2
  fi
done
assert_contains "$(cat "$LEAD_PATCH")" "toolName: subagent_claude_code" "lead profile exposes the subagent_claude_code tool"

report_and_exit
