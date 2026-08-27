#!/usr/bin/env bash
# P3.4: update discovery (lib/update_discovery.sh). No real network — the
# registry seam is redirected to tests/fixtures/update-registry/fixture.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
source "$ROOT_DIR/lib/capability_probe.sh"
source "$ROOT_DIR/lib/inventory.sh"
source "$ROOT_DIR/lib/update_discovery.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_UPDATE_REGISTRY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/fixture"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1

widget-core:
  tested: "2.4.1"
  source: "npm:@acme/widget-core"
  channel: "next"
  critical: true
  required_capabilities: []

pytool:
  tested: "0.9.50"
  source: "pypi:pytool"
  critical: false
  required_capabilities: []

git:
  tested: "2.49.0"
  source: "system"
  critical: true
  required_capabilities: []
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"

# --- status classification ---
assert_eq "not_applicable" "$(update_component_status 2.49.0 "" system)" "system tools are out of scope"
assert_eq "not_installed"  "$(update_component_status "" 2.4.1 npm)" "nothing installed -> not_installed"
assert_eq "unknown"        "$(update_component_status 2.4.1 "" npm)" "registry unreachable -> unknown, never a guess"
assert_eq "up_to_date"     "$(update_component_status 2.4.1 2.4.1 npm)" "same version -> up_to_date"
assert_eq "update_available" "$(update_component_status 2.4.0 2.4.1 npm)" "older installed -> update_available"
assert_eq "ahead"          "$(update_component_status 2.5.0 2.4.1 npm)" "newer installed than published -> ahead"

# --- dist-tag channel awareness ---
export FIXTURE__acme_widget_core__next="2.6.0"
export FIXTURE__acme_widget_core__latest="2.4.1"
assert_eq "2.6.0" "$(update_available_version widget-core)" "npm lookups follow the component's declared dist-tag channel"

# --- PyPI path ---
export FIXTURE_pytool="0.9.51"
assert_eq "0.9.51" "$(update_available_version pytool)" "a pypi-sourced component resolves via the pypi branch"

# --- update_check rows + JSON ---
export FIXTURE_pytool="0.9.50"   # up to date
rows="$(update_check)"
wc_row="$(printf '%s\n' "$rows" | grep '^widget-core')"
# widget-core isn't installed on the test box -> not_installed, even though
# the registry has a newer version. An update needs something to update.
assert_eq "not_installed" "$(printf '%s' "$wc_row" | cut -f5)" "an uninstalled component is not_installed, not update_available"
git_row="$(printf '%s\n' "$rows" | grep '^git')"
assert_eq "not_applicable" "$(printf '%s' "$git_row" | cut -f5)" "system git row is not_applicable"

json="$(update_check | node "$ROOT_DIR/lib/json-tools.mjs" update-check-build)"
assert_contains "$json" '"schema_version":1' "update-check JSON has a schema_version"
assert_contains "$json" '"checked_at"' "update-check JSON records when it ran"
assert_contains "$json" '"updates_available":[]' "no installed component needs an update on the test box"
assert_contains "$json" '"name":"widget-core"' "every component appears in the JSON"

# --- offline path ---
unset AGENT_UPDATE_REGISTRY_FIXTURE
export AGENT_UPDATE_OFFLINE=1
assert_eq "" "$(update_available_version widget-core)" "offline mode returns nothing, not an error"
assert_eq "unknown" "$(update_component_status 2.4.1 "$(update_available_version widget-core)" npm)" "offline -> status unknown"
unset AGENT_UPDATE_OFFLINE

# --- check is read-only: no files created, git HEAD unchanged ---
export AGENT_UPDATE_REGISTRY_FIXTURE="$ROOT_DIR/tests/fixtures/update-registry/fixture"
before="$(git -C "$ROOT_DIR" status --porcelain; git -C "$ROOT_DIR" rev-parse HEAD)"
update_check >/dev/null
update_check_json >/dev/null
after="$(git -C "$ROOT_DIR" status --porcelain; git -C "$ROOT_DIR" rev-parse HEAD)"
assert_eq "$before" "$after" "update check/plan discovery mutates nothing in the repo"

report_and_exit
