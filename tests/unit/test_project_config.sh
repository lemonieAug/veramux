#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/project_config.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# No .agent/config.yaml at all: every helper falls back to the caller's default.
mkdir -p "$TMP/bare"
assert_eq "" "$(project_config_extra_high_risk_paths "$TMP/bare")" "no overrides -> no extra high-risk paths"
project_config_always_review "$TMP/bare"
assert_eq "1" "$?" "no overrides -> always_review defaults false"
project_config_bool "$TMP/bare" research enabled true
assert_eq "0" "$?" "no overrides -> caller default (true) wins"
project_config_bool "$TMP/bare" research enabled false
assert_eq "1" "$?" "no overrides -> caller default (false) wins"
assert_eq "" "$(project_config_validation_command "$TMP/bare" test)" "no overrides -> no validation command override"
assert_eq "legacy" "$(project_config_orchestration_value "$TMP/bare" engine legacy)" "no orchestration config keeps supplied default"

# With .agent/config.yaml
mkdir -p "$TMP/withconfig/.agent"
cat > "$TMP/withconfig/.agent/config.yaml" <<'EOF'
review:
  high_risk_paths:
    - "src/auth/**"
    - "prisma/**"
  always_review: true

research:
  enabled: false

validation:
  test: "make unit-test"

orchestration:
  engine: dsh
  tool_mode: auto
EOF

assert_eq "$(printf 'src/auth/**\nprisma/**')" "$(project_config_extra_high_risk_paths "$TMP/withconfig")" "extra high-risk paths read correctly"
project_config_always_review "$TMP/withconfig"
assert_eq "0" "$?" "always_review: true overrides the default"
project_config_bool "$TMP/withconfig" research enabled true
assert_eq "1" "$?" "research.enabled: false overrides a true default"
assert_eq "make unit-test" "$(project_config_validation_command "$TMP/withconfig" test)" "validation.test override read correctly"
assert_eq "" "$(project_config_validation_command "$TMP/withconfig" lint)" "validation.lint has no override -> empty"
assert_eq "dsh" "$(project_config_orchestration_value "$TMP/withconfig" engine legacy)" "orchestration engine is read from project config"
assert_eq "auto" "$(project_config_orchestration_value "$TMP/withconfig" tool_mode native)" "orchestration tool mode is read from project config"

report_and_exit
