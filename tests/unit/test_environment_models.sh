#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
# shellcheck source=../../lib/environment.sh
source "$ROOT_DIR/lib/environment.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ENV_FILE="$TMP/models.env"

unset VERAMUX_DEEPSEEK_MODEL VERAMUX_OPENAI_MODEL

# Defaults also cover a missing file.
assert_eq "deepseek-chat" "$(env_orchestrator_deepseek_model "$TMP/missing.env")" "DeepSeek defaults when no value exists"
assert_eq "gpt-5-mini" "$(env_orchestrator_openai_model "$TMP/missing.env")" "OpenAI defaults when no value exists"

cat > "$ENV_FILE" <<'EOF'
VERAMUX_DEEPSEEK_MODEL=deepseek-from-file
VERAMUX_OPENAI_MODEL=openai-from-file
EOF
assert_eq "deepseek-from-file" "$(env_orchestrator_deepseek_model "$ENV_FILE")" "DeepSeek reads .env"
assert_eq "openai-from-file" "$(env_orchestrator_openai_model "$ENV_FILE")" "OpenAI reads .env"

assert_eq "deepseek-from-process" "$(VERAMUX_DEEPSEEK_MODEL=deepseek-from-process env_orchestrator_deepseek_model "$ENV_FILE")" "process environment wins for DeepSeek"
assert_eq "openai-from-process" "$(VERAMUX_OPENAI_MODEL=openai-from-process env_orchestrator_openai_model "$ENV_FILE")" "process environment wins for OpenAI"

cat > "$ENV_FILE" <<'EOF'
 export VERAMUX_DEEPSEEK_MODEL =  deepseek-with-whitespace  
export VERAMUX_OPENAI_MODEL = openai-with-whitespace
EOF
assert_eq "deepseek-with-whitespace" "$(env_orchestrator_deepseek_model "$ENV_FILE")" "export prefix and whitespace are accepted"
assert_eq "openai-with-whitespace" "$(env_orchestrator_openai_model "$ENV_FILE")" "whitespace is removed from OpenAI values"

cat > "$ENV_FILE" <<'EOF'
VERAMUX_DEEPSEEK_MODEL='deepseek-single-quoted'
VERAMUX_OPENAI_MODEL="openai-double-quoted"
EOF
assert_eq "deepseek-single-quoted" "$(env_orchestrator_deepseek_model "$ENV_FILE")" "single quotes are removed"
assert_eq "openai-double-quoted" "$(env_orchestrator_openai_model "$ENV_FILE")" "double quotes are removed"

cat > "$ENV_FILE" <<'EOF'
VERAMUX_DEEPSEEK_MODEL=deepseek-first-valid
VERAMUX_DEEPSEEK_MODEL=deepseek-second-valid
EOF
assert_eq "deepseek-first-valid" "$(env_orchestrator_deepseek_model "$ENV_FILE")" "first valid duplicate wins"

cat > "$ENV_FILE" <<'EOF'
VERAMUX_DEEPSEEK_MODEL=
VERAMUX_OPENAI_MODEL=""
UNRELATED_MODEL=ignored
EOF
assert_eq "deepseek-chat" "$(env_orchestrator_deepseek_model "$ENV_FILE")" "blank DeepSeek value falls back to default"
assert_eq "gpt-5-mini" "$(env_orchestrator_openai_model "$ENV_FILE")" "empty quoted OpenAI value falls back to default"

MARKER="$TMP/should-not-run"
printf '%s\n' "VERAMUX_DEEPSEEK_MODEL=\$(touch $MARKER)" > "$ENV_FILE"
assert_eq "\$(touch $MARKER)" "$(env_orchestrator_deepseek_model "$ENV_FILE")" ".env shell syntax remains literal"
assert_eq "no" "$([ -e "$MARKER" ] && printf yes || printf no)" ".env command substitution is never executed"

report_and_exit
