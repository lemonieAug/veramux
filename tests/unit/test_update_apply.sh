#!/usr/bin/env bash
# P3.9 + P3.19: controlled apply, incl. adversarial "install succeeds but
# binary breaks", "critical capability lost", "regression appeared". No
# network, no LLM — every boundary is a fixture.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
for m in policy environment version_drift compat capability_probe inventory state_paths \
         run_lifecycle journal update_discovery update_plan migration_detect snapshot \
         update_stage update_verify update_apply; do
  source "$ROOT_DIR/lib/$m.sh"
done
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE_HOME="$TMP/state"
export HOME="$TMP/home"; mkdir -p "$HOME"
mkdir -p "$TMP/installed"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
acme-tool:
  tested: "1.0.0"
  source: "npm:@acme/tool"
  critical: false
  required_capabilities: []
  rollback: "npm i -g @acme/tool@<old>"
core-thing:
  tested: "1.0.0"
  source: "npm:@acme/core"
  critical: true
  required_capabilities:
    - core-backend
  rollback: "npm i -g @acme/core@<old>"
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"

# installed-version fixture: reads a per-component file
cat > "$TMP/inv" <<EOF
#!/usr/bin/env bash
cat "$TMP/installed/\$1" 2>/dev/null
EOF
chmod +x "$TMP/inv"; export AGENT_INVENTORY_FIXTURE="$TMP/inv"
echo "1.0.0" > "$TMP/installed/acme-tool"
echo "1.0.0" > "$TMP/installed/core-thing"

# registry fixture
export AGENT_UPDATE_REGISTRY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/fixture"
export FIXTURE__acme_tool="1.1.0"
export FIXTURE__acme_core="2.0.0"

# staging fixture: fabricate a fake bin reporting the requested version
cat > "$TMP/stage" <<'EOF'
#!/usr/bin/env bash
dest=$4; mkdir -p "$dest/node_modules/.bin"
name=claude-mem; case "$2" in *tool*) name=acme-tool;; *core*) name=core-thing;; esac
printf '#!/usr/bin/env bash\necho "%s"\n' "$3" > "$dest/node_modules/.bin/$name"
chmod +x "$dest/node_modules/.bin/$name"
EOF
chmod +x "$TMP/stage"; export AGENT_STAGE_INSTALL_FIXTURE="$TMP/stage"

# apply-install fixture: normally records the new version; env vars force bad behaviour
cat > "$TMP/apply" <<EOF
#!/usr/bin/env bash
comp=\$1; ver=\$2
[ "\${APPLY_FAIL:-0}" = "1" ] && exit 1
if [ "\${APPLY_WRONG_VERSION:-0}" = "1" ]; then echo "0.0.1" > "$TMP/installed/\$comp"; exit 0; fi
echo "\$ver" > "$TMP/installed/\$comp"
exit 0
EOF
chmod +x "$TMP/apply"; export AGENT_APPLY_INSTALL_FIXTURE="$TMP/apply"

export AGENT_VERIFY_REGRESSION_CMD="true"   # regression suite passes by default

# ---------------------------------------------------------------
# 1. happy path
# ---------------------------------------------------------------
out="$(update_apply_run acme-tool --yes 2>&1)"
assert_contains "$out" "UPDATE_SUCCESS" "a clean update reports UPDATE_SUCCESS"
assert_eq "1.1.0" "$(cat "$TMP/installed/acme-tool")" "the component is actually at the new version"
assert_contains "$out" "snapshot" "a snapshot was taken before applying"
snap_count=$(ls -1d "$TMP/state/snapshots"/snap-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "1" "$snap_count" "exactly one pre-update snapshot exists"

# ---------------------------------------------------------------
# 2. refuse non-interactive apply without --yes (nothing changes)
# ---------------------------------------------------------------
echo "1.0.0" > "$TMP/installed/acme-tool"
out="$(update_apply_run acme-tool </dev/null 2>&1)"
assert_contains "$out" "refusing to apply non-interactively without --yes" "apply refuses without --yes"
assert_eq "1.0.0" "$(cat "$TMP/installed/acme-tool")" "a refused apply changes nothing"

# ---------------------------------------------------------------
# 3. adversarial: package install succeeds but the binary is broken
#    (staging catches a version mismatch BEFORE the real install)
# ---------------------------------------------------------------
cat > "$TMP/stage_bad" <<'EOF'
#!/usr/bin/env bash
dest=$4; mkdir -p "$dest/node_modules/.bin"
printf '#!/usr/bin/env bash\necho "0.0.0-broken"\n' > "$dest/node_modules/.bin/acme-tool"
chmod +x "$dest/node_modules/.bin/acme-tool"
EOF
chmod +x "$TMP/stage_bad"
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/stage_bad"
out="$(update_apply_run acme-tool --yes 2>&1)"
export AGENT_STAGE_INSTALL_FIXTURE="$TMP/stage"
assert_contains "$out" "APPLY ABORTED" "a candidate that fails isolated staging aborts the apply"
assert_eq "1.0.0" "$(cat "$TMP/installed/acme-tool")" "a staging failure leaves the real install untouched"

# ---------------------------------------------------------------
# 4. adversarial: install runs but leaves the wrong version on disk
# ---------------------------------------------------------------
export APPLY_WRONG_VERSION=1
out="$(update_apply_run acme-tool --yes 2>&1)"
unset APPLY_WRONG_VERSION
assert_contains "$out" "UPDATE_FAILED_ROLLBACK_AVAILABLE" "a post-install version mismatch fails with rollback available"
assert_contains "$out" "agent update rollback" "the failure tells the user how to roll back"
echo "1.0.0" > "$TMP/installed/acme-tool"

# ---------------------------------------------------------------
# 5. adversarial: a regression appears after updating a critical component
# ---------------------------------------------------------------
echo "1.0.0" > "$TMP/installed/core-thing"
export AGENT_VERIFY_REGRESSION_CMD="false"
out="$(update_apply_run core-thing --yes 2>&1)"
export AGENT_VERIFY_REGRESSION_CMD="true"
assert_contains "$out" "UPDATE_FAILED_ROLLBACK_AVAILABLE" "a regression after updating a critical component fails the apply"
assert_contains "$out" "regression" "the failure names the regression as the cause"

# ---------------------------------------------------------------
# 6. system component is rejected
# ---------------------------------------------------------------
cat >> "$TMP/compat.yaml" <<'EOF'
git:
  tested: "2.49.0"
  source: "system"
  critical: true
  required_capabilities: []
EOF
out="$(update_apply_run git --yes 2>&1)"
assert_contains "$out" "system component" "apply refuses a system component"

report_and_exit
