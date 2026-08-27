#!/usr/bin/env bash
# P3.18: user backup / restore. DISTINCT from a pre-update snapshot
# (lib/snapshot.sh): a snapshot is automatic, internal, and keyed by id for
# rollback; a BACKUP is operator-initiated and portable — a single archive
# of the stack's *configuration* you can copy to a new VPS. It never
# contains a project, an OAuth token, an API key, a cookie, or an SSH key.
# Restore preserves whatever secrets are currently on the target machine.
# No LLM. Sourced by bin/agent. Must not be executed directly.
set -euo pipefail

_BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# backup_create [--out <path>]
# Reuses lib/snapshot.sh's capture (same secret handling) to build the tree,
# then tars it. Prints the archive path.
backup_create() {
  local out=""
  [ "${1:-}" = "--out" ] && { out="$2"; shift 2; }

  local id dir
  id="$(snapshot_create "user-backup" 2>/dev/null)" || { echo "error: could not capture config" >&2; return 1; }
  dir="$(snapshot_dir "$id")"

  [ -n "$out" ] || { mkdir -p "$(state_backups_dir)"; out="$(state_backups_dir)/agent-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"; }
  mkdir -p "$(dirname "$out")"

  if tar -czf "$out" -C "$dir" . 2>/dev/null; then
    rm -rf "$dir"   # the snapshot tree was only a staging area for the archive
    chmod 600 "$out" 2>/dev/null || true
    echo "backup written: $out"
    echo "  contains: stack config (policies, versions.yaml, compat.yaml), DSH profile config,"
    echo "            non-secret claude-mem settings, skill files, a version inventory."
    echo "  does NOT contain: any project, OAuth token, API key, cookie, or SSH key."
    printf '%s\n' "$out"
  else
    echo "error: tar failed" >&2
    return 1
  fi
}

backup_list() {
  local root; root="$(state_backups_dir)"
  [ -d "$root" ] || { echo "no backups yet"; return 0; }
  ls -1t "$root"/agent-backup-*.tar.gz 2>/dev/null || echo "no backups yet"
}

# backup_restore <archive> [--yes]
# 1. validate  2. show what will be restored  3. preserve current secrets
# 4. restore config  5. run doctor.
backup_restore() {
  local archive="${1:-}" assume_yes=0
  [ "${2:-}" = "--yes" ] && assume_yes=1
  [ -f "$archive" ] || { echo "error: no such backup archive: $archive" >&2; return 1; }

  local tmp; tmp="$(mktemp -d)"
  if ! tar -xzf "$archive" -C "$tmp" 2>/dev/null; then
    echo "error: could not extract $archive (corrupt or not an agent backup)" >&2
    rm -rf "$tmp"; return 1
  fi
  if [ ! -f "$tmp/manifest.json" ]; then
    echo "error: $archive has no manifest.json — not an agent backup" >&2
    rm -rf "$tmp"; return 1
  fi

  echo "restore: from $archive"
  cat "$tmp/manifest.json" | sed 's/^/  /'; echo
  echo "restore: the following will be OVERWRITTEN from the backup:"
  (cd "$tmp/stack-config" 2>/dev/null && find . -type f | sed 's|^\./|  '"$(_snapshot_root_dir)"'/|')
  if [ -s "$tmp/secrets-manifest.jsonl" ]; then
    echo "restore: these files hold a secret and will be LEFT AS-IS on this machine (not overwritten):"
    sed 's/^/  /' "$tmp/secrets-manifest.jsonl"
  fi

  if [ "$assume_yes" -ne 1 ]; then
    if [ -t 0 ]; then
      printf 'proceed with restore? [y/N] '; local r; read -r r
      case "$r" in y|Y|yes) ;; *) echo "aborted — nothing changed."; rm -rf "$tmp"; return 1 ;; esac
    else
      echo "refusing to restore non-interactively without --yes (nothing changed)." >&2
      rm -rf "$tmp"; return 1
    fi
  fi

  # reuse rollback's tree restorer — it already skips secret-bearing paths
  _rollback_restore_tree "$tmp/stack-config" "$(_snapshot_root_dir)" "$tmp/secrets-manifest.jsonl"
  [ -d "$tmp/dsh-profiles" ] && _rollback_restore_tree "$tmp/dsh-profiles" "$(env_dsh_home)/profiles" "$tmp/secrets-manifest.jsonl"
  [ -d "$tmp/claude-mem" ] && _rollback_restore_tree "$tmp/claude-mem" "$HOME/.claude-mem" "$tmp/secrets-manifest.jsonl"
  [ -d "$tmp/skills" ] && _rollback_restore_tree "$tmp/skills" "$HOME/.claude" "$tmp/secrets-manifest.jsonl"
  rm -rf "$tmp"

  echo "restore: running agent doctor ..."
  bash "$(_snapshot_root_dir)/scripts/doctor.sh" >/dev/null 2>&1 \
    && echo "RESTORE_OK: config restored and doctor is clean." \
    || echo "RESTORE_DONE_WITH_WARNINGS: config restored, but 'agent doctor' reports issues — run it and review."
}
