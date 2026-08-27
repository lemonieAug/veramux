#!/usr/bin/env bash
# P3.16: release manifest (lib/release.sh). No LLM.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
for m in policy environment version_drift compat capability_probe inventory release; do
  source "$ROOT_DIR/lib/$m.sh"
done
set +e

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENT_RELEASES_DIR="$TMP/releases"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
widget:
  tested: "1.0.0"
  source: "npm:@acme/widget"
  critical: true
  required_capabilities: []
git:
  tested: "2.49.0"
  source: "system"
  critical: false
  required_capabilities: []
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"

cat > "$TMP/inv" <<EOF
#!/usr/bin/env bash
case "\$1" in widget) echo "1.0.0";; git) echo "2.49.0";; esac
EOF
chmod +x "$TMP/inv"; export AGENT_INVENTORY_FIXTURE="$TMP/inv"

# --- create ---
release_create 1.0.0 --benchmark-offline pass >/dev/null
f="$(release_path 1.0.0)"
assert_eq "1" "$([ -f "$f" ] && echo 1 || echo 0)" "release_create writes a manifest"
assert_contains "$(cat "$f")" 'stack_version: "1.0.0"' "the manifest records the stack version"
assert_contains "$(cat "$f")" 'widget: "1.0.0"' "the manifest pins each component version from the live inventory"
assert_contains "$(cat "$f")" 'deterministic: "pass"' "the manifest records the offline benchmark result it was told"
assert_contains "$(cat "$f")" 'live: "not-run"' "the manifest never fabricates a live benchmark result"

assert_contains "$(release_list)" "1.0.0" "release_list shows the new release"
assert_eq "1.0.0" "$(release_pin 1.0.0 widget)" "release_pin returns the pinned version for install to use"

# --- verify: machine matches ---
out="$(release_verify 1.0.0 2>&1)"; rc=$?
# (benchmark_suite isn't sourced here, so the benchmark line is skipped)
assert_eq "0" "$rc" "a machine whose versions match the release verifies"
assert_contains "$out" "RELEASE_VERIFIED" "verification reports success"

# --- verify: machine drifted ---
cat > "$TMP/inv" <<EOF
#!/usr/bin/env bash
case "\$1" in widget) echo "2.0.0";; git) echo "2.49.0";; esac
EOF
out="$(release_verify 1.0.0 2>&1)"; rc=$?
assert_eq "1" "$rc" "a drifted machine fails verification"
assert_contains "$out" "RELEASE_MISMATCH" "verification reports the mismatch"
assert_contains "$out" "widget: release wants 1.0.0, machine has 2.0.0" "the specific drift is named"

assert_exit_code "1" "verifying an unknown release fails" release_verify 9.9.9

report_and_exit
