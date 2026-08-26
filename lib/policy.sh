#!/usr/bin/env bash
# Tiny reader for our own small, line-based policy YAML files (policies/*.yaml,
# project .agent/config.yaml). Not a general YAML parser — see
# policies/safety.yaml for why we don't want one. Supports exactly the shape
# our own files use: a top-level "section:" key followed by 2-space-indented
# "key: value" lines, one level deep.
set -euo pipefail

# policy_get <file> <section> <key> [default]
# Prints the value of policies/*.yaml's section.key, or default (or empty)
# when the file, section, or key is absent.
policy_get() {
  local file="$1" section="$2" key="$3" default="${4:-}"
  local value
  value="$(awk -v section="$section" -v key="$key" '
    $0 ~ ("^" section ":") { insection=1; next }
    /^[^[:space:]#]/ { insection=0 }
    insection && $0 ~ ("^  " key ":") {
      sub("^  " key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$file" 2>/dev/null | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/[[:space:]]*#.*$//')"
  if [ -z "$value" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

# policy_get_bool <file> <section> <key> <default: true|false>
policy_get_bool() {
  local file="$1" section="$2" key="$3" default="$4"
  local value
  value="$(policy_get "$file" "$section" "$key" "$default")"
  [ "$value" = "true" ]
}

# policy_get_list <file> <top_level_key>
# Prints a top-level YAML list's items, one per line, e.g.:
#   ignore_patterns:
#     - ".env"
#     - "*.pem"
# Only handles this exact shape (our own files never nest lists under a
# section) — same approach as lib/redact.sh always used, generalized so
# lib/risk.sh and project overrides can reuse it instead of duplicating it.
policy_get_list() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ ("^" key ":") { flag=1; next }
    /^[a-zA-Z]/ { flag=0 }
    flag && /^[[:space:]]*-/ { print }
  ' "$file" 2>/dev/null | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/'
}

# policy_get_nested_list <file> <section> <key>
# Same as policy_get_list, but for a list one level deeper, e.g.:
#   review:
#     high_risk_paths:
#       - "src/auth/**"
policy_get_nested_list() {
  local file="$1" section="$2" key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ ("^" section ":") { insection=1; next }
    insection && /^[^[:space:]#]/ { insection=0 }
    insection && $0 ~ ("^  " key ":") { inkey=1; next }
    insection && inkey && /^  [a-zA-Z]/ { inkey=0 }
    insection && inkey && /^[[:space:]]*-/ { print }
  ' "$file" 2>/dev/null | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/'
}
