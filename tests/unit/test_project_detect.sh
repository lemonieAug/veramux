#!/usr/bin/env bash
# P2.2/P2.3: extended ecosystem detection, package-manager detection
# (lockfile-priority, ambiguity, explicit override), and validation-profile
# assembly. No LLM quota used.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/project.sh"
source "$ROOT_DIR/lib/project_config.sh"
source "$ROOT_DIR/lib/validation.sh"
source "$ROOT_DIR/lib/project_detect.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Extended ecosystem tags ---
go_dir="$TMP/go-proj"; mkdir -p "$go_dir"; : > "$go_dir/go.mod"
assert_contains "$(project_detect_ecosystems_extended "$go_dir")" "go" "detects Go via go.mod"

rust_dir="$TMP/rust-proj"; mkdir -p "$rust_dir"; : > "$rust_dir/Cargo.toml"
assert_contains "$(project_detect_ecosystems_extended "$rust_dir")" "rust" "detects Rust via Cargo.toml"

php_dir="$TMP/php-proj"; mkdir -p "$php_dir"; : > "$php_dir/composer.json"
assert_contains "$(project_detect_ecosystems_extended "$php_dir")" "php" "detects PHP via composer.json"

java_dir="$TMP/java-proj"; mkdir -p "$java_dir"; : > "$java_dir/pom.xml"
assert_contains "$(project_detect_ecosystems_extended "$java_dir")" "java" "detects Java via pom.xml"

gradle_dir="$TMP/gradle-proj"; mkdir -p "$gradle_dir"; : > "$gradle_dir/build.gradle.kts"
assert_contains "$(project_detect_ecosystems_extended "$gradle_dir")" "java" "detects Java via build.gradle.kts"

docker_dir="$TMP/docker-proj"; mkdir -p "$docker_dir"; : > "$docker_dir/Dockerfile"
assert_contains "$(project_detect_ecosystems_extended "$docker_dir")" "docker" "detects Docker via Dockerfile"

# --- Package manager detection: lockfile priority, never machine-installed ---
pnpm_dir="$TMP/pnpm-proj"; mkdir -p "$pnpm_dir"
echo '{}' > "$pnpm_dir/package.json"; : > "$pnpm_dir/pnpm-lock.yaml"
assert_eq "pnpm" "$(project_detect_package_manager "$pnpm_dir")" "pnpm-lock.yaml selects pnpm"

yarn_dir="$TMP/yarn-proj"; mkdir -p "$yarn_dir"
echo '{}' > "$yarn_dir/package.json"; : > "$yarn_dir/yarn.lock"
assert_eq "yarn" "$(project_detect_package_manager "$yarn_dir")" "yarn.lock selects yarn"

npm_dir="$TMP/npm-proj"; mkdir -p "$npm_dir"
echo '{}' > "$npm_dir/package.json"; : > "$npm_dir/package-lock.json"
assert_eq "npm" "$(project_detect_package_manager "$npm_dir")" "package-lock.json selects npm"

bun_dir="$TMP/bun-proj"; mkdir -p "$bun_dir"
echo '{}' > "$bun_dir/package.json"; : > "$bun_dir/bun.lock"
assert_eq "bun" "$(project_detect_package_manager "$bun_dir")" "bun.lock selects bun"

no_lock_dir="$TMP/no-lock-proj"; mkdir -p "$no_lock_dir"
echo '{}' > "$no_lock_dir/package.json"
assert_eq "npm" "$(project_detect_package_manager "$no_lock_dir")" "no lockfile defaults to npm (always available)"

no_pkg_dir="$TMP/no-pkg-proj"; mkdir -p "$no_pkg_dir"
assert_exit_code "1" "no package.json at all returns 1" project_detect_package_manager "$no_pkg_dir"

ambiguous_dir="$TMP/ambiguous-proj"; mkdir -p "$ambiguous_dir"
echo '{}' > "$ambiguous_dir/package.json"
: > "$ambiguous_dir/pnpm-lock.yaml"
: > "$ambiguous_dir/yarn.lock"
assert_exit_code "2" "two lockfiles present is reported as ambiguous, not guessed" project_detect_package_manager "$ambiguous_dir"

# project_pm_resolve falls back to npm on ambiguity with a stderr warning,
# and never silently picks one of the ambiguous candidates.
resolved="$(project_pm_resolve "$ambiguous_dir" 2>/tmp/pm_resolve_warn.out)"
assert_eq "npm" "$resolved" "ambiguous case resolves to the safe npm fallback"
assert_contains "$(cat /tmp/pm_resolve_warn.out)" "ambiguous package manager" "ambiguity is reported, not silently swallowed"

# --- Explicit project override always wins over detection ---
override_dir="$TMP/override-proj"; mkdir -p "$override_dir/.agent"
echo '{}' > "$override_dir/package.json"; : > "$override_dir/pnpm-lock.yaml"
cat > "$override_dir/.agent/config.yaml" <<'EOF'
validation:
  package_manager: "yarn"
EOF
assert_eq "yarn" "$(project_pm_resolve "$override_dir")" "explicit .agent/config.yaml override wins over lockfile detection"

# --- project_pm_command: bun always uses explicit `run` (bun test !=
# package.json's test script) ---
assert_eq "npm test" "$(project_pm_command npm test)" "npm test command"
assert_eq "npm run lint" "$(project_pm_command npm lint)" "npm run lint command"
assert_eq "pnpm test" "$(project_pm_command pnpm test)" "pnpm test command"
assert_eq "pnpm run build" "$(project_pm_command pnpm build)" "pnpm run build command"
assert_eq "yarn lint" "$(project_pm_command yarn lint)" "yarn lint command (no 'run' needed)"
assert_eq "bun run test" "$(project_pm_command bun test)" "bun run test (never bare 'bun test')"
assert_eq "bun run typecheck" "$(project_pm_command bun typecheck)" "bun run typecheck command"

# --- validation_detect_commands actually uses the resolved package manager ---
pnpm_validation_dir="$TMP/pnpm-validation-proj"; mkdir -p "$pnpm_validation_dir"
cat > "$pnpm_validation_dir/package.json" <<'EOF'
{"scripts":{"test":"echo t","lint":"echo l"}}
EOF
: > "$pnpm_validation_dir/pnpm-lock.yaml"
commands="$(validation_detect_commands "$pnpm_validation_dir" false)"
assert_contains "$commands" $'test\tpnpm test' "pnpm project gets pnpm test, not npm test"
assert_contains "$commands" $'lint\tpnpm run lint' "pnpm project gets pnpm run lint"

bun_validation_dir="$TMP/bun-validation-proj"; mkdir -p "$bun_validation_dir"
cat > "$bun_validation_dir/package.json" <<'EOF'
{"scripts":{"test":"echo t"}}
EOF
: > "$bun_validation_dir/bun.lock"
commands_bun="$(validation_detect_commands "$bun_validation_dir" false)"
assert_contains "$commands_bun" $'test\tbun run test' "bun project gets 'bun run test', never bare 'bun test'"

# --- Framework detection: tiny, evidence-based ---
next_dir="$TMP/next-proj"; mkdir -p "$next_dir"
echo '{"dependencies":{"next":"14.0.0"}}' > "$next_dir/package.json"
assert_contains "$(project_detect_framework "$next_dir")" "next" "detects Next.js from package.json dependency"

plain_dir="$TMP/plain-proj"; mkdir -p "$plain_dir"
echo '{}' > "$plain_dir/package.json"
assert_eq "" "$(project_detect_framework "$plain_dir")" "no framework detected for a plain package.json"

# --- Validation profile assembly (P2.3) ---
profile_dir="$TMP/profile-proj"; mkdir -p "$profile_dir"
cat > "$profile_dir/package.json" <<'EOF'
{"scripts":{"test":"echo t","lint":"echo l"}}
EOF
: > "$profile_dir/pnpm-lock.yaml"
profile_json="$(project_profile_build "$profile_dir")"
assert_contains "$profile_json" '"package_manager":"pnpm"' "profile records the resolved package manager"
assert_contains "$profile_json" '"languages":["node"]' "profile records detected languages"
assert_contains "$profile_json" '"test":"pnpm test"' "profile records the resolved test command"
assert_contains "$profile_json" '"detected_at"' "profile records a detection timestamp"
assert_contains "$profile_json" '"source_files_that_justify_detection"' "profile records justifying source files"
assert_contains "$profile_json" 'pnpm-lock.yaml' "profile lists pnpm-lock.yaml as justifying evidence"

report_and_exit
