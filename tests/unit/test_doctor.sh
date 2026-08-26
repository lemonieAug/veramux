#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

setup_fake_dsh_home() {
  local home="$1"
  mkdir -p "$home/profiles/lead" "$home/profiles/reviewer/codex-home"
  cat > "$home/profiles/lead/package.json" <<'EOF'
{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","@deepseek-ai/dsh-headless","@deepseek-ai/dsh-subagent-claude-code"]}}}
EOF
  cp "$ROOT_DIR/harness/profiles/lead/cordis.patch.yml" "$home/profiles/lead/cordis.patch.yml"
  cat > "$home/profiles/reviewer/package.json" <<'EOF'
{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","@deepseek-ai/dsh-headless","@deepseek-ai/dsh-subagent-codex"]}}}
EOF
  local codex_home="$home/profiles/reviewer/codex-home"
  sed "s#__CODEX_REVIEWER_HOME__#${codex_home}#" \
    "$ROOT_DIR/harness/profiles/reviewer/cordis.patch.yml" > "$home/profiles/reviewer/cordis.patch.yml"
  cp "$ROOT_DIR/harness/config/codex-reviewer-home/config.toml" "$codex_home/config.toml"
}

# The full PATH, minus any directory that actually provides a `dsh`
# executable — everything else (git, node, pnpm, grep, awk, find, bash
# itself...) stays available, so doctor's other checks still run sensibly.
# This works whether or not `dsh` happens to be installed on the machine
# running this test suite.
PATH_WITHOUT_DSH=""
IFS=':' read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  if [ ! -x "$_dir/dsh" ] && [ ! -x "$_dir/dsh.cmd" ] && [ ! -x "$_dir/dsh.exe" ]; then
    PATH_WITHOUT_DSH="${PATH_WITHOUT_DSH:+$PATH_WITHOUT_DSH:}$_dir"
  fi
done

# 1) dsh missing entirely -> blocking failure, exit 2
FAKE_HOME_NO_DSH="$TMP/no-dsh-home"
setup_fake_dsh_home "$FAKE_HOME_NO_DSH"
code=0
DSH_HOME="$FAKE_HOME_NO_DSH" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" >/tmp/doctor1.out 2>&1 || code=$?
assert_eq "2" "$code" "doctor exits 2 when dsh is missing (blocking)"
assert_contains "$(cat /tmp/doctor1.out)" "dsh not found" "doctor names the missing tool"

# 2) profiles missing entirely -> at least a non-zero exit
FAKE_HOME_EMPTY="$TMP/empty-home"
mkdir -p "$FAKE_HOME_EMPTY"
code=0
DSH_HOME="$FAKE_HOME_EMPTY" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" >/tmp/doctor2.out 2>&1 || code=$?
if [ "$code" -ge 1 ]; then PASS_COUNT=$((PASS_COUNT + 1)); else FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: doctor should not exit 0 with no profiles configured" >&2; fi
assert_contains "$(cat /tmp/doctor2.out)" "lead profile missing" "doctor names the missing lead profile"

# 3) a hardcoded credential in a profile config is a blocking failure
FAKE_HOME_LEAK="$TMP/leak-home"
setup_fake_dsh_home "$FAKE_HOME_LEAK"
cat >> "$FAKE_HOME_LEAK/profiles/lead/cordis.patch.yml" <<'EOF'
- id: subagent-claude-code
  config:
    env:
      ANTHROPIC_API_KEY: !!js process.env.ANTHROPIC_API_KEY
EOF
code=0
DSH_HOME="$FAKE_HOME_LEAK" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" >/tmp/doctor3.out 2>&1 || code=$?
assert_eq "2" "$code" "doctor treats a hardcoded API key as blocking"
assert_contains "$(cat /tmp/doctor3.out)" "ANTHROPIC_API_KEY" "doctor names which credential leaked"

report_and_exit
