#!/usr/bin/env bash
# P3.3: capability probes (lib/capability_probe.sh).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/policy.sh"
source "$ROOT_DIR/lib/environment.sh"
source "$ROOT_DIR/lib/version_drift.sh"
source "$ROOT_DIR/lib/compat.sh"
source "$ROOT_DIR/lib/capability_probe.sh"
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- probe output shape ---
out="$(capability_probe deepseek-harness claude-code-subagent)"
status="${out%%$'\t'*}"
assert_eq "1" "$([ "$status" = pass ] || [ "$status" = fail ] || [ "$status" = unknown ] && echo 1 || echo 0)" "a probe returns one of pass|fail|unknown"

# --- not installed -> unknown, never a silent pass ---
export DSH_HOME="$TMP/dsh-empty"
mkdir -p "$DSH_HOME"
assert_eq "unknown" "$(capability_probe deepseek-harness claude-code-subagent | cut -f1)" "a missing lead profile probes unknown, not pass"
assert_eq "unknown" "$(capability_probe codex reviewer-read-only-patch-policy | cut -f1)" "a missing reviewer patch probes unknown"

# --- a well-formed fake profile -> pass ---
export DSH_HOME="$TMP/dsh-good"
mkdir -p "$DSH_HOME/profiles/lead" "$DSH_HOME/profiles/reviewer/codex-home"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-claude-code":"0.3.220"}}' > "$DSH_HOME/profiles/lead/package.json"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-codex":"0.147.0"}}' > "$DSH_HOME/profiles/reviewer/package.json"
cat > "$DSH_HOME/profiles/reviewer/cordis.patch.yml" <<'EOF'
patch:
  - id: "tool-fs"
    enabled: false
  - id: "tool-bash"
    enabled: false
  - id: "tool-str-replace-editor"
    enabled: false
EOF
echo 'sandbox_mode = "read-only"' > "$DSH_HOME/profiles/reviewer/codex-home/config.toml"

assert_eq "pass" "$(capability_probe deepseek-harness claude-code-subagent | cut -f1)" "a lead profile with the bundle probes pass"
assert_eq "pass" "$(capability_probe deepseek-harness codex-subagent | cut -f1)" "a reviewer profile with the bundle probes pass"
assert_eq "pass" "$(capability_probe codex reviewer-read-only-patch-policy | cut -f1)" "a reviewer that disables write rows AND pins read-only sandbox probes pass"

# --- reviewer that lost its read-only enforcement -> fail ---
export DSH_HOME="$TMP/dsh-bad-reviewer"
mkdir -p "$DSH_HOME/profiles/reviewer/codex-home"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-codex":"0.147.0"}}' > "$DSH_HOME/profiles/reviewer/package.json"
cat > "$DSH_HOME/profiles/reviewer/cordis.patch.yml" <<'EOF'
patch:
  - id: "tool-fs"
    enabled: true
EOF
echo 'sandbox_mode = "workspace-write"' > "$DSH_HOME/profiles/reviewer/codex-home/config.toml"
assert_eq "fail" "$(capability_probe codex reviewer-read-only-patch-policy | cut -f1)" "a reviewer that re-enables write tools probes FAIL"

# --- lead profile that lost the bundle -> fail ---
export DSH_HOME="$TMP/dsh-bad-lead"
mkdir -p "$DSH_HOME/profiles/lead"
echo '{"dependencies":{"something-else":"1.0.0"}}' > "$DSH_HOME/profiles/lead/package.json"
assert_eq "fail" "$(capability_probe deepseek-harness claude-code-subagent | cut -f1)" "a lead profile missing the bundle probes FAIL"

# --- capability_verdict aggregation ---
export DSH_HOME="$TMP/dsh-good"
# widget manifest so we control which capabilities are required
cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
deepseek-harness:
  tested: "0.1.1-rc.2"
  critical: true
  required_capabilities:
    - claude-code-subagent
    - codex-subagent
EOF
export AGENT_COMPAT_FILE="$TMP/compat.yaml"
assert_eq "OK" "$(capability_verdict deepseek-harness)" "all required capabilities passing -> OK"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
deepseek-harness:
  tested: "0.1.1-rc.2"
  critical: true
  required_capabilities:
    - claude-code-subagent
    - cwd-propagation
EOF
assert_eq "UNVERIFIED" "$(capability_verdict deepseek-harness)" "a pass + an unverifiable capability -> UNVERIFIED (not OK)"

cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
deepseek-harness:
  tested: "0.1.1-rc.2"
  critical: true
  required_capabilities:
    - code-mode
EOF
DSH_HOME="$TMP/dsh-good" # dsh binary still absent -> code-mode probes unknown
assert_eq "UNVERIFIED" "$(capability_verdict deepseek-harness)" "code-mode with no dsh binary is UNVERIFIED, never OK"

# an actual failure dominates
export DSH_HOME="$TMP/dsh-bad-lead"
cat > "$TMP/compat.yaml" <<'EOF'
schema_version: 1
deepseek-harness:
  tested: "0.1.1-rc.2"
  critical: true
  required_capabilities:
    - claude-code-subagent
    - cwd-propagation
EOF
assert_eq "INCOMPATIBLE" "$(capability_verdict deepseek-harness)" "any failing capability -> INCOMPATIBLE, overriding unknowns"

report_and_exit
