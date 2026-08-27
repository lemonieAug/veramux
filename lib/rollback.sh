#!/usr/bin/env bash
# P3.11: rollback. Restores the configuration state captured by a pre-update
# snapshot (lib/snapshot.sh) and, where technically possible, reinstalls the
# versions that snapshot recorded. It NEVER overwrites a file that currently
# holds a secret (those are left in place and flagged), and it is HONEST
# when a rollback cannot be complete — an irreversible data migration
# (lib/migration_detect.sh) makes the result ROLLBACK_PARTIAL, not
# ROLLBACK_COMPLETE. Rollback is only "done" after its own verification
# pass. No LLM. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_ROLLBACK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROLLBACK_DEFAULT_ROOT="$(cd "$_ROLLBACK_LIB_DIR/.." && pwd)"
# AGENT_STACK_ROOT: see lib/snapshot.sh — a test points this at a copy.
_rollback_root_dir() { printf '%s' "${AGENT_STACK_ROOT:-$_ROLLBACK_DEFAULT_ROOT}"; }

# _rollback_install <component> <version>
# Reinstalls a pinned older version. Seam: AGENT_ROLLBACK_INSTALL_FIXTURE
# (script "<component> <version>"). Returns the installer exit code; a
# nonzero is recorded, not fatal (config rollback still stands).
_rollback_install() {
  local component="$1" version="$2"
  if [ -n "${AGENT_ROLLBACK_INSTALL_FIXTURE:-}" ]; then
    "$AGENT_ROLLBACK_INSTALL_FIXTURE" "$component" "$version"; return $?
  fi
  local scheme pkg
  scheme="$(_update_source_scheme "$(compat_source "$component")")"
  pkg="$(_update_source_pkg "$(compat_source "$component")")"
  case "$scheme" in
    npm)    npm install -g "$pkg@$version" --loglevel=error ;;
    bundle) command -v dsh >/dev/null 2>&1 && dsh plugin --profile "$([ "$component" = codex ] && echo reviewer || echo lead)" add "$pkg@$version" ;;
    pypi)   command -v uv >/dev/null 2>&1 && uv tool install "$pkg==$version" ;;
    *) return 0 ;;
  esac
}

rollback_latest_snapshot() {
  local root; root="$(state_snapshots_dir)"
  [ -d "$root" ] || return 0
  ls -1d "$root"/snap-* 2>/dev/null | sort | tail -1 | xargs -r basename
}

# _rollback_restore_tree <snapshot-subdir> <dest-root> <secrets-manifest>
# Copies every file from the snapshot subtree back to dest-root, EXCEPT any
# path listed in the secrets manifest (left in place, reported).
_rollback_restore_tree() {
  local src="$1" dest="$2" secrets="$3"
  [ -d "$src" ] || return 0
  local f rel
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    if [ -f "$secrets" ] && grep -qF "\"$dest/$rel\"" "$secrets" 2>/dev/null; then
      echo "  SKIP (holds a secret — left as-is): $dest/$rel"
      continue
    fi
    mkdir -p "$(dirname "$dest/$rel")"
    cp "$f" "$dest/$rel"
    echo "  restored: $dest/$rel"
  done < <(find "$src" -type f)
}

# rollback_run [snapshot-id]
rollback_run() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(rollback_latest_snapshot)"
  if [ -z "$id" ]; then echo "error: no snapshot to roll back to." >&2; return 1; fi
  local dir; dir="$(snapshot_dir "$id")"
  [ -d "$dir" ] || { echo "error: no such snapshot: $id" >&2; return 1; }

  echo "rollback: using snapshot $id"
  cat "$dir/manifest.json" 2>/dev/null | sed 's/^/  /'; echo
  local reason; reason="$(node "$_ROLLBACK_LIB_DIR/json-tools.mjs" get-field reason < "$dir/manifest.json" 2>/dev/null)"

  echo "rollback: restoring stack config into $(_rollback_root_dir)"
  _rollback_restore_tree "$dir/stack-config" "$(_rollback_root_dir)" "$dir/secrets-manifest.jsonl"

  local dsh_home; dsh_home="$(env_dsh_home)"
  if [ -d "$dir/dsh-profiles" ]; then
    echo "rollback: restoring DSH profile config into $dsh_home/profiles"
    _rollback_restore_tree "$dir/dsh-profiles" "$dsh_home/profiles" "$dir/secrets-manifest.jsonl"
  fi
  if [ -d "$dir/claude-mem" ]; then
    echo "rollback: restoring claude-mem settings (non-secret keys only)"
    _rollback_restore_tree "$dir/claude-mem" "$HOME/.claude-mem" "$dir/secrets-manifest.jsonl"
  fi
  if [ -d "$dir/skills" ]; then
    echo "rollback: restoring skill files"
    _rollback_restore_tree "$dir/skills" "$HOME/.claude" "$dir/secrets-manifest.jsonl"
  fi

  # reinstall recorded versions where we can
  local partial=0 any_migration=0
  if [ -f "$dir/versions.json" ]; then
    echo "rollback: reinstalling recorded component versions"
    local rows
    rows="$(node -e '
      try {
        const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))
        for (const c of j.components || []) {
          if (c.installed_version && c.source && /^(npm|bundle|pypi):/.test(c.source))
            console.log(c.name + "\t" + c.installed_version)
        }
      } catch {}
    ' "$dir/versions.json" 2>/dev/null)"
    local name ver
    while IFS=$'\t' read -r name ver; do
      [ -n "$name" ] || continue
      echo "  reinstalling $name@$ver"
      if ! _rollback_install "$name" "$ver"; then
        echo "  WARNING: could not reinstall $name@$ver — do it manually" >&2
        partial=1
      fi
      # was this the component whose forward update was irreversible?
      case "$reason" in *"$name@"*) migration_is_irreversible "$name" "$ver" "99.0.0" && any_migration=1 ;; esac
    done <<< "$rows"
  fi

  # verify
  echo "rollback: verifying ..."
  local rg_out rg_tok
  rg_out="$(update_verify_regression)"
  printf '%s\n' "$rg_out" | sed 's/^/  /'
  rg_tok="$(update_verify_result "$rg_out")"
  [ "$rg_tok" = "regression_failed" ] && partial=1

  if [ "$any_migration" -eq 1 ]; then
    echo "ROLLBACK_PARTIAL: config and versions restored from $id, but a data migration that ran during the update is NOT reversible — verify the affected component's data manually."
    return 0
  fi
  if [ "$partial" -eq 1 ]; then
    echo "ROLLBACK_PARTIAL: config restored from $id, but at least one reinstall or the verification step did not fully succeed — see the warnings above."
    return 1
  fi
  echo "ROLLBACK_COMPLETE: stack restored to the state captured in $id and verification passed."
  return 0
}
