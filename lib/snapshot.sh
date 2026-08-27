#!/usr/bin/env bash
# P3.8: pre-update configuration snapshots. Before `agent update apply`
# touches anything, this captures ONLY the configuration state needed to put
# the stack back the way it was: this repo's policy/manifest files, the DSH
# profile *config* (not node_modules), the non-secret parts of claude-mem's
# settings, the installed skill files, and a version inventory. Secrets are
# never copied — a file that contains one is recorded as a path + sha256 in
# secrets-manifest.json instead. Zero LLM. Sourced by bin/agent. Must not be
# executed directly.
set -euo pipefail

_SNAPSHOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SNAPSHOT_DEFAULT_ROOT="$(cd "$_SNAPSHOT_LIB_DIR/.." && pwd)"
# AGENT_STACK_ROOT lets a test point snapshot/rollback at a throwaway copy of
# the repo instead of the live checkout. Evaluated at call time.
_snapshot_root_dir() { printf '%s' "${AGENT_STACK_ROOT:-$_SNAPSHOT_DEFAULT_ROOT}"; }

# Key names (case-insensitive substring) that mark a value as a secret.
_SNAPSHOT_SECRET_KEYS='api[_-]?key|token|secret|password|passwd|credential|cookie|authorization|bearer|private[_-]?key|client[_-]?secret|session'

snapshot_id_generate() {
  local ts rand=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  [ -n "$rand" ] || rand="$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
  printf 'snap-%s-%s' "$ts" "${rand:0:6}"
}

snapshot_dir() { printf '%s/%s\n' "$(state_snapshots_dir)" "$1"; }

_snapshot_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  else node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1" 2>/dev/null
  fi
}

# _snapshot_copy_config <src-file> <dest-file> <secrets-manifest>
# Copies a config file into the snapshot. If it is JSON, secret-valued keys
# are nulled out in the copy. If it is non-JSON and matches a secret
# pattern by content, only its path+hash is recorded (no copy).
_snapshot_copy_config() {
  local src="$1" dest="$2" manifest="$3"
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"

  if printf '%s' "$src" | grep -qE '\.json$'; then
    local redacted
    redacted="$(node -e '
      const fs = require("fs")
      const re = new RegExp(process.argv[2], "i")
      let hadSecret = false
      const scrub = (o) => {
        if (Array.isArray(o)) return o.map(scrub)
        if (o && typeof o === "object") {
          const out = {}
          for (const [k, v] of Object.entries(o)) {
            if (re.test(k) && typeof v !== "object") { out[k] = null; hadSecret = true }
            else out[k] = scrub(v)
          }
          return out
        }
        return o
      }
      try {
        const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
        const s = scrub(j)
        process.stderr.write(hadSecret ? "SECRET\n" : "CLEAN\n")
        process.stdout.write(JSON.stringify(s, null, 2))
      } catch (e) { process.stderr.write("PARSE_ERROR\n"); process.exit(3) }
    ' "$src" "$_SNAPSHOT_SECRET_KEYS" 2>"$dest.flag")"
    local flag; flag="$(cat "$dest.flag" 2>/dev/null)"; rm -f "$dest.flag"
    if [ "$flag" = "PARSE_ERROR" ]; then
      printf '{"path":"%s","sha256":"%s","note":"unparseable JSON — not copied"}\n' "$src" "$(_snapshot_sha256 "$src")" >> "$manifest"
      return 0
    fi
    printf '%s\n' "$redacted" > "$dest"
    [ "$flag" = "SECRET" ] && printf '{"path":"%s","sha256":"%s","note":"copied with secret-valued keys nulled"}\n' "$src" "$(_snapshot_sha256 "$src")" >> "$manifest"
    return 0
  fi

  # Non-JSON: copy, unless the content itself carries a secret-shaped line.
  if grep -qiE "($_SNAPSHOT_SECRET_KEYS)[\"'[:space:]]*[:=]" "$src" 2>/dev/null; then
    printf '{"path":"%s","sha256":"%s","note":"contains secret-shaped lines — recorded by hash only, not copied"}\n' "$src" "$(_snapshot_sha256 "$src")" >> "$manifest"
  else
    cp "$src" "$dest"
  fi
}

# snapshot_create [reason]
# Prints the snapshot id on stdout. Everything else goes to stderr.
snapshot_create() {
  local reason="${1:-manual}"
  local id dir
  id="$(snapshot_id_generate)"
  dir="$(snapshot_dir "$id")"
  mkdir -p "$dir/stack-config" "$dir/dsh-profiles" "$dir/skills"
  chmod 700 "$dir" 2>/dev/null || true
  : > "$dir/secrets-manifest.jsonl"

  echo "snapshot $id -> $dir" >&2

  # 1. this repo's own config / manifests
  local f
  for f in versions.yaml compat.yaml .env.example; do
    [ -f "$(_snapshot_root_dir)/$f" ] && cp "$(_snapshot_root_dir)/$f" "$dir/stack-config/$f"
  done
  for d in policies harness; do
    [ -d "$(_snapshot_root_dir)/$d" ] && cp -r "$(_snapshot_root_dir)/$d" "$dir/stack-config/$d"
  done

  # 2. DSH profile CONFIG only (never node_modules)
  local dsh_home; dsh_home="$(env_dsh_home)"
  local p
  for p in lead reviewer; do
    for f in package.json cordis.patch.yml; do
      _snapshot_copy_config "$dsh_home/profiles/$p/$f" "$dir/dsh-profiles/$p/$f" "$dir/secrets-manifest.jsonl"
    done
    _snapshot_copy_config "$dsh_home/profiles/$p/codex-home/config.toml" "$dir/dsh-profiles/$p/codex-home/config.toml" "$dir/secrets-manifest.jsonl"
  done

  # 3. claude-mem settings (secrets scrubbed)
  _snapshot_copy_config "$HOME/.claude-mem/settings.json" "$dir/claude-mem/settings.json" "$dir/secrets-manifest.jsonl"

  # 4. installed skill files
  local s
  for s in graphify agent-reach; do
    _snapshot_copy_config "$HOME/.claude/skills/$s/SKILL.md" "$dir/skills/$s/SKILL.md" "$dir/secrets-manifest.jsonl"
  done
  _snapshot_copy_config "$HOME/.claude/CLAUDE.md" "$dir/skills/CLAUDE.md" "$dir/secrets-manifest.jsonl"

  # 5. version inventory + manifest
  inventory_json > "$dir/versions.json" 2>/dev/null || echo '{}' > "$dir/versions.json"
  local repo_head
  repo_head="$(git -C "$(_snapshot_root_dir)" rev-parse HEAD 2>/dev/null || echo unknown)"
  local secrets_n file_n
  secrets_n="$(grep -c . "$dir/secrets-manifest.jsonl" 2>/dev/null)"; secrets_n="${secrets_n:-0}"
  node "$_SNAPSHOT_LIB_DIR/json-tools.mjs" build-object \
    "schema_version=1" "snapshot_id=$id" "reason=$reason" \
    "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "repo_head=$repo_head" "dsh_home=$dsh_home" \
    "secrets_recorded=$secrets_n" \
    > "$dir/manifest.json"
  chmod -R go-rwx "$dir" 2>/dev/null || true

  file_n="$(find "$dir" -type f | wc -l | tr -d ' ')"
  echo "snapshot complete: $file_n files, $secrets_n secret-bearing file(s) recorded by hash only" >&2
  printf '%s\n' "$id"
}

snapshot_list() {
  local root; root="$(state_snapshots_dir)"
  [ -d "$root" ] || { echo "no snapshots yet"; return 0; }
  local d
  for d in "$root"/snap-*; do
    [ -d "$d" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$d")" \
      "$(node "$_SNAPSHOT_LIB_DIR/json-tools.mjs" get-field created_at < "$d/manifest.json" 2>/dev/null)" \
      "$(node "$_SNAPSHOT_LIB_DIR/json-tools.mjs" get-field reason < "$d/manifest.json" 2>/dev/null)"
  done
}

snapshot_show() {
  local id="$1" dir; dir="$(snapshot_dir "$id")"
  [ -d "$dir" ] || { echo "error: no such snapshot: $id" >&2; return 1; }
  echo "snapshot: $id"
  cat "$dir/manifest.json"; echo
  echo "files:"; (cd "$dir" && find . -type f | sed 's/^/  /' | sort)
  if [ -s "$dir/secrets-manifest.jsonl" ]; then
    echo "secret-bearing files (recorded by hash, NOT copied):"
    sed 's/^/  /' "$dir/secrets-manifest.jsonl"
  fi
}
