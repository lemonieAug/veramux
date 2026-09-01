#!/usr/bin/env bash
# P3.19: adversarial update scenarios A-E (F/G/H are covered in
# test_update_apply.sh and test_rollback.sh). No network, no LLM.
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

# ==============================================================
# A. a DSH candidate that no longer wires up the Codex backend
#    -> capability probe FAILS -> component is INCOMPATIBLE
# ==============================================================
export DSH_HOME="$TMP/dsh-no-codex"
mkdir -p "$DSH_HOME/profiles/lead" "$DSH_HOME/profiles/reviewer"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-claude-code":"0.1.1-rc.2"}}' > "$DSH_HOME/profiles/lead/package.json"
echo '{"dependencies":{"something-not-codex":"1.0.0"}}' > "$DSH_HOME/profiles/reviewer/package.json"
assert_eq "fail" "$(capability_probe deepseek-harness codex-subagent | cut -f1)" "A: a candidate that drops the Codex bundle probes FAIL"
assert_eq "INCOMPATIBLE" "$(capability_verdict codex)" "A: the codex component is INCOMPATIBLE"
vout="$(update_verify_component codex 0.1.1-rc.2)"
assert_eq "verify_capability_failed" "$(update_verify_result "$vout")" "A: post-update verification rejects a candidate that lost the Codex backend"

# ==============================================================
# B. a DSH candidate whose --help no longer advertises Code Mode
#    -> probe FAILS (a stub 'dsh' on PATH says nothing about code mode)
# ==============================================================
mkdir -p "$TMP/fakebin"
printf '#!/usr/bin/env bash\necho "dsh 0.2.0"\necho "commands: run, plugin, profile"\n' > "$TMP/fakebin/dsh"
chmod +x "$TMP/fakebin/dsh"
PATH="$TMP/fakebin:$PATH" out="$(capability_probe deepseek-harness code-mode)"
assert_eq "fail" "$(printf '%s' "$out" | cut -f1)" "B: a dsh whose --help drops Code Mode probes FAIL"

# ==============================================================
# C. Graphify update: binary present but the skill landed nowhere we look
#    -> skill verification FAILS
# ==============================================================
printf '#!/usr/bin/env bash\necho "graphify 0.10.0"\n' > "$TMP/fakebin/graphify"
chmod +x "$TMP/fakebin/graphify"
export HOME="$TMP/home-no-skill"; mkdir -p "$HOME/.claude"
mkdir -p "$TMP/workspace-no-skill"
out="$(cd "$TMP/workspace-no-skill" && PATH="$TMP/fakebin:$PATH" capability_probe graphify skill-installed-where-expected)"
assert_eq "fail" "$(printf '%s' "$out" | cut -f1)" "C: a Graphify install with no SKILL.md at an expected path probes FAIL"
assert_contains "$out" "SKILL.md" "C: the failure explains the skill file is missing"

# ==============================================================
# D. claude-mem config-schema / major change -> migration detected
#    BEFORE apply (the plan surfaces it and forces HIGH + partial rollback)
# ==============================================================
sev="$(migration_detect claude-mem 13.16.0 14.0.0 | sed -n 's/^severity: //p')"
assert_eq "irreversible" "$sev" "D: a claude-mem major bump is flagged as an irreversible migration up front"
assert_contains "$(migration_detect claude-mem 13.16.0 14.0.0)" "settings.json" "D: the migration notice points at the settings/storage that would change"

# ==============================================================
# E. Agent-Reach update that changes/loses its doctor command
#    -> capability probe detects the changed surface
# ==============================================================
printf '#!/usr/bin/env bash\necho "agent-reach 2.0.0"\necho "usage: agent-reach [fetch|search]"\n' > "$TMP/fakebin/agent-reach"
chmod +x "$TMP/fakebin/agent-reach"
out="$(PATH="$TMP/fakebin:$PATH" capability_probe agent-reach doctor-command)"
assert_eq "fail" "$(printf '%s' "$out" | cut -f1)" "E: an agent-reach whose --help drops 'doctor' probes FAIL"

# ==============================================================
# and the positive control: a healthy dsh_home still verifies
# ==============================================================
export DSH_HOME="$TMP/dsh-ok"
mkdir -p "$DSH_HOME/profiles/lead" "$DSH_HOME/profiles/reviewer/codex-home"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-claude-code":"0.1.1-rc.2"}}' > "$DSH_HOME/profiles/lead/package.json"
echo '{"dependencies":{"@deepseek-ai/dsh-subagent-codex":"0.1.1-rc.2"}}' > "$DSH_HOME/profiles/reviewer/package.json"
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
assert_eq "pass" "$(capability_probe deepseek-harness codex-subagent | cut -f1)" "control: a healthy reviewer profile still probes pass"

report_and_exit
