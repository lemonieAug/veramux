#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/validation.sh"
# These libs set -e for production use; turn it back off for this test file.
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Node detection ---
node_dir="$TMP/node-proj"
mkdir -p "$node_dir"
cat > "$node_dir/package.json" <<'EOF'
{"scripts":{"test":"echo running-tests","lint":"echo running-lint"}}
EOF
commands="$(validation_detect_commands "$node_dir" false)"
assert_contains "$commands" $'test\tnpm test' "node: detects test script"
assert_contains "$commands" $'lint\tnpm run lint' "node: detects lint script"
assert_not_contains "$commands" "typecheck" "node: no typecheck script means none detected"

# npm's default placeholder test script must not count as a real test
node_dir2="$TMP/node-proj-default"
mkdir -p "$node_dir2"
cat > "$node_dir2/package.json" <<'EOF'
{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}
EOF
commands2="$(validation_detect_commands "$node_dir2" false)"
assert_not_contains "$commands2" "test" "node: placeholder test script is ignored"

# build only runs when forced or no test/typecheck present
node_dir3="$TMP/node-proj-build-only"
mkdir -p "$node_dir3"
cat > "$node_dir3/package.json" <<'EOF'
{"scripts":{"build":"echo building"}}
EOF
commands3="$(validation_detect_commands "$node_dir3" false)"
assert_contains "$commands3" "build" "node: build runs when nothing else is available"

node_dir4="$TMP/node-proj-build-skipped"
mkdir -p "$node_dir4"
cat > "$node_dir4/package.json" <<'EOF'
{"scripts":{"test":"echo test","build":"echo building"}}
EOF
commands4="$(validation_detect_commands "$node_dir4" false)"
assert_not_contains "$commands4" "build" "node: build is skipped when test already covers validation"

# --- Python detection ---
py_dir="$TMP/py-proj"
mkdir -p "$py_dir/tests"
cat > "$py_dir/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
EOF
if env_has_cmd pytest; then
  commands5="$(validation_detect_commands "$py_dir" false)"
  assert_contains "$commands5" "pytest" "python: detects pytest when available"
else
  echo "skipping pytest-presence assertion: pytest not installed in this environment"
fi

# --- Makefile fallback ---
make_dir="$TMP/make-proj"
mkdir -p "$make_dir"
cat > "$make_dir/Makefile" <<'EOF'
test:
	echo testing

lint:
	echo linting
EOF
commands6="$(validation_detect_commands "$make_dir" false)"
assert_contains "$commands6" $'test\tmake test' "makefile: detects test target"
assert_contains "$commands6" $'lint\tmake lint' "makefile: detects lint target"

report_and_exit
