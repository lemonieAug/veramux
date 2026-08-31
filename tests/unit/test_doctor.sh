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

# Relay-provider states are reported independently from the remaining doctor
# checks. Values are canaries and must never be printed.
FAKE_HOME_PROVIDER="$TMP/provider-home"
setup_fake_dsh_home "$FAKE_HOME_PROVIDER"
cat > "$FAKE_HOME_PROVIDER/.env" <<'EOF'
VERAMUX_DEEPSEEK_MODEL=deepseek-doctor-file-model
VERAMUX_OPENAI_MODEL=openai-doctor-file-model
EOF

out_both="$(VERAMUX_DEEPSEEK_API_KEY=deepseek-doctor-canary VERAMUX_OPENAI_API_KEY=openai-doctor-canary DSH_HOME="$FAKE_HOME_PROVIDER" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_both" "DeepSeek primary" "doctor reports DeepSeek as primary when both providers exist"
assert_contains "$out_both" "OpenAI fallback" "doctor reports OpenAI as fallback when both providers exist"
assert_contains "$out_both" "default engine: legacy" "doctor reports the hybrid migration default"
assert_contains "$out_both" "programmatic primitive: code exists upstream, but is disabled by Veramux policy" "doctor reports the CodeRuntime policy boundary"
assert_not_contains "$out_both" "deepseek-doctor-canary" "doctor never prints the DeepSeek key"
assert_not_contains "$out_both" "openai-doctor-canary" "doctor never prints the OpenAI key"

# Doctor is the real call site that resolves models with its DSH_HOME/.env
# path. Process model variables are explicitly absent so this proves the file
# values enter the displayed provider resolution rather than only the helper.
out_file_models="$(env -u VERAMUX_DEEPSEEK_MODEL -u VERAMUX_OPENAI_MODEL VERAMUX_DEEPSEEK_API_KEY=deepseek-doctor-canary VERAMUX_OPENAI_API_KEY=openai-doctor-canary DSH_HOME="$FAKE_HOME_PROVIDER" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_file_models" "DeepSeek primary (deepseek-doctor-file-model)" "doctor resolves DeepSeek model from DSH .env"
assert_contains "$out_file_models" "OpenAI fallback (openai-doctor-file-model)" "doctor resolves OpenAI model from DSH .env"

out_primary="$(VERAMUX_DEEPSEEK_API_KEY=deepseek-doctor-canary DSH_HOME="$FAKE_HOME_PROVIDER" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_primary" "OpenAI fallback is not configured" "DeepSeek-only is a supported doctor state"

out_degraded="$(VERAMUX_OPENAI_API_KEY=openai-doctor-canary DSH_HOME="$FAKE_HOME_PROVIDER" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_degraded" "DeepSeek primary is not configured" "OpenAI-only is reported as degraded"
assert_contains "$out_degraded" "[degraded]" "OpenAI-only is non-blocking provider degradation"

out_absent="$(DSH_HOME="$FAKE_HOME_PROVIDER" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_absent" "no relay credential is configured" "doctor blocks when both relay providers are absent"

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

# --- P2.14/P2.18: corrupt run journal detection ---
CORRUPT_STATE="$TMP/corrupt-state"
mkdir -p "$CORRUPT_STATE/runs/some-project/20260101T000000Z-abcdef"
echo '{ this is not valid json' > "$CORRUPT_STATE/runs/some-project/20260101T000000Z-abcdef/run.json"
out_corrupt="$(AGENT_STATE_HOME="$CORRUPT_STATE" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_corrupt" "corrupt run.json file(s) detected" "doctor detects a corrupt run journal"

CLEAN_STATE="$TMP/clean-state"
mkdir -p "$CLEAN_STATE/runs/some-project/20260101T000000Z-abcdef"
echo '{"schema_version":1,"state":"COMPLETED"}' > "$CLEAN_STATE/runs/some-project/20260101T000000Z-abcdef/run.json"
out_clean="$(AGENT_STATE_HOME="$CLEAN_STATE" PATH="$PATH_WITHOUT_DSH" bash "$ROOT_DIR/scripts/doctor.sh" 2>&1)"
assert_contains "$out_clean" "no corrupt run journal detected" "doctor reports clean journals as clean, not a false positive"

report_and_exit
