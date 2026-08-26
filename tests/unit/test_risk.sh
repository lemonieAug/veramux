#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/risk.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

setup_repo() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -r "$ROOT_DIR/tests/fixtures/sample-node-project/." "$dir/"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t.com -c user.name=t add -A >/dev/null 2>&1
  git -C "$dir" -c user.email=t@t.com -c user.name=t commit -q -m init >/dev/null 2>&1
}

# LOW
setup_repo "$TMP/low"
echo "# notes" > "$TMP/low/NOTES.md"
assert_eq "low" "$(risk_classify "$TMP/low")" "docs-only change is LOW"

# LOW: no changes at all
setup_repo "$TMP/none"
assert_eq "low" "$(risk_classify "$TMP/none")" "no changes is LOW"

# MEDIUM
setup_repo "$TMP/medium"
echo "  return a + b;" >> "$TMP/medium/add.js"
assert_eq "medium" "$(risk_classify "$TMP/medium")" "ordinary source change is MEDIUM"

# HIGH: path pattern
setup_repo "$TMP/high-path"
mkdir -p "$TMP/high-path/src/auth"
echo "// x" > "$TMP/high-path/src/auth/login.js"
git -C "$TMP/high-path" add -A >/dev/null 2>&1
assert_eq "high" "$(risk_classify "$TMP/high-path")" "auth path is HIGH"

# HIGH: one-line auth change stays HIGH even though the diff is tiny
setup_repo "$TMP/high-tiny"
mkdir -p "$TMP/high-tiny/src/auth"
echo "x" > "$TMP/high-tiny/src/auth/session.js"
git -C "$TMP/high-tiny" add -A >/dev/null 2>&1
git -C "$TMP/high-tiny" -c user.email=t@t.com -c user.name=t commit -q -m "add session file" >/dev/null 2>&1
echo "y" >> "$TMP/high-tiny/src/auth/session.js"
assert_eq "high" "$(risk_classify "$TMP/high-tiny")" "a one-line auth change is still HIGH"

# HIGH: dependency manifest
setup_repo "$TMP/high-pkg"
echo '  "x": true' >> "$TMP/high-pkg/package.json"
assert_eq "high" "$(risk_classify "$TMP/high-pkg")" "package.json change is HIGH"

# HIGH: dangerous keyword in an otherwise ordinary file
setup_repo "$TMP/high-kw"
echo 'child_process.exec("ls")' >> "$TMP/high-kw/add.js"
assert_eq "high" "$(risk_classify "$TMP/high-kw")" "dangerous keyword in diff is HIGH"

# Project override widens HIGH (never narrows it)
setup_repo "$TMP/override"
mkdir -p "$TMP/override/custom"
echo "// x" > "$TMP/override/custom/thing.js"
git -C "$TMP/override" add -A >/dev/null 2>&1
assert_eq "medium" "$(risk_classify "$TMP/override")" "custom path is MEDIUM without an override"
assert_eq "high" "$(risk_classify "$TMP/override" "custom/**")" "the same change is HIGH once a project override adds the path"

# Review-tier settings
assert_eq "false" "$(risk_review_setting low codex)" "low tier: codex disabled"
assert_eq "true" "$(risk_review_setting medium codex)" "medium tier: codex enabled"
assert_eq "true" "$(risk_review_setting high codex)" "high tier: codex enabled"
assert_eq "true" "$(risk_review_setting high verification)" "high tier: verification enabled"
assert_eq "false" "$(risk_review_setting medium verification)" "medium tier: verification disabled"

report_and_exit
