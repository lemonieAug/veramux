#!/usr/bin/env bash
# P3.6: isolated update staging (lib/update_stage.sh). No network — the
# install seam is redirected to a fixture that fabricates a fake install.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
source "$ROOT_DIR/lib/inventory.sh"
source "$ROOT_DIR/lib/state_paths.sh"
source "$ROOT_DIR/lib/update_discovery.sh"
source "$ROOT_DIR/lib/update_stage.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
claude-mem:
  tested: "13.16.0"
  source: "npm:claude-mem"
  critical: false
  required_capabilities: []
deepseek-harness:
  tested: "0.1.1-rc.2"
  source: "bundle:@deepseek-ai/dsh-subagent-claude-code"
  critical: true
  required_capabilities: []
git:
  tested: "2.49.0"
  source: "system"
  critical: true
  required_capabilities: []
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"

# fixture: fabricate a working install whose binary reports $version
cat > "$TMP/install-ok" <<'EOF'
#!/usr/bin/env bash
scheme=$1; pkg=$2; version=$3; dest=$4
mkdir -p "$dest/node_modules/.bin"
printf '#!/usr/bin/env bash\necho "%s"\n' "$version" > "$dest/node_modules/.bin/claude-mem"
chmod +x "$dest/node_modules/.bin/claude-mem"
EOF
chmod +x "$TMP/install-ok"

# fixture: install "succeeds" but the binary reports the WRONG version
cat > "$TMP/install-wrongver" <<'EOF'
#!/usr/bin/env bash
dest=$4
mkdir -p "$dest/node_modules/.bin"
printf '#!/usr/bin/env bash\necho "9.9.9"\n' > "$dest/node_modules/.bin/claude-mem"
chmod +x "$dest/node_modules/.bin/claude-mem"
EOF
chmod +x "$TMP/install-wrongver"

# fixture: install itself fails
cat > "$TMP/install-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/install-fail"

# --- happy path ---
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/install-ok"
out="$(stage_candidate claude-mem 13.16.1)"
assert_eq "staged_ok" "$(stage_result "$out")" "a candidate that installs and reports the right version stages ok"
assert_contains "$out" "isolated" "the staging report says the real install is untouched"

# --- version mismatch is caught ---
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/install-wrongver"
out="$(stage_candidate claude-mem 13.16.1)"
assert_eq "staged_failed" "$(stage_result "$out")" "a candidate whose binary reports a different version fails staging"

# --- install failure ---
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/install-fail"
out="$(stage_candidate claude-mem 13.16.1)"
assert_eq "staged_failed" "$(stage_result "$out")" "an install that errors fails staging"

# --- system component: not applicable ---
unset AGENT_STAGE_INSTALL_FIXTURE
out="$(stage_candidate git 2.50.0)"
assert_eq "staging_not_available" "$(stage_result "$out")" "a system component cannot be staged in isolation"

# --- bundle with no dsh present: not available ---
hide_test_commands dsh
out="$(stage_candidate deepseek-harness 0.1.2)"
assert_eq "staging_not_available" "$(stage_result "$out")" "a DSH profile bundle is staging_not_available without a real dsh"
show_test_commands

# --- staging leaves nothing behind ---
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/install-ok"
stage_candidate claude-mem 13.16.1 >/dev/null
leftover="$(find "$TMP/state/staging" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$leftover" "the staging directory is cleaned up after use (no leftover installs)"

report_and_exit
