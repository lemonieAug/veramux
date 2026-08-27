#!/usr/bin/env bash
# P2.15: version/compatibility drift detection.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
set +e

assert_eq "equal" "$(version_drift_compare "0.1.1-rc.2" "0.1.1-rc.2")" "identical strings are equal"
assert_eq "newer" "$(version_drift_compare "0.3.246" "0.3.220")" "a higher patch is newer"
assert_eq "older" "$(version_drift_compare "0.3.200" "0.3.220")" "a lower patch is older"
assert_eq "newer" "$(version_drift_compare "1.0.0" "0.9.9")" "a higher major is newer"
assert_eq "older" "$(version_drift_compare "0.9.9" "1.0.0")" "a lower major is older"
assert_eq "newer" "$(version_drift_compare "0.1.1-rc.3" "0.1.1-rc.2")" "same X.Y.Z, different prerelease suffix reports as newer (flagged, not silently equal)"
assert_eq "unknown" "$(version_drift_compare "not-a-version" "0.1.1")" "an unparsable version reports unknown, not a guess"

assert_eq "MISSING" "$(version_drift_status "" "0.1.1")" "empty installed version is MISSING"
assert_eq "SUPPORTED" "$(version_drift_status "0.1.1-rc.2" "0.1.1-rc.2")" "exact match is SUPPORTED"
assert_eq "NEWER_UNTESTED" "$(version_drift_status "0.3.246" "0.3.220")" "a newer installed version is NEWER_UNTESTED"
assert_eq "OLDER_UNSUPPORTED" "$(version_drift_status "0.3.200" "0.3.220")" "an older installed version is OLDER_UNSUPPORTED"
assert_eq "UNKNOWN" "$(version_drift_status "garbage" "0.1.1")" "an unparsable installed version is UNKNOWN, not silently SUPPORTED"

# --- feature-probe: reads the version really resolved in a profile's own
# node_modules, not a claimed version number ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/profiles/lead/node_modules/@anthropic-ai/claude-agent-sdk"
echo '{"name":"@anthropic-ai/claude-agent-sdk","version":"0.3.220"}' > "$TMP/profiles/lead/node_modules/@anthropic-ai/claude-agent-sdk/package.json"
assert_eq "0.3.220" "$(version_drift_installed_claude_agent_sdk "$TMP")" "reads the real bundled SDK version from the lead profile's node_modules"

empty_home="$TMP/empty"
mkdir -p "$empty_home"
assert_eq "" "$(version_drift_installed_claude_agent_sdk "$empty_home")" "no bundled SDK found prints nothing (not an error) when the profile isn't installed yet"

report_and_exit
