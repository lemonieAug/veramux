#!/usr/bin/env bash
# Workspace resolution and project ecosystem detection.
# Sourced by bin/agent and scripts/doctor.sh. Must not be executed directly.
set -euo pipefail

# Resolves an arbitrary user-supplied path argument to an absolute,
# existing, readable directory. Fails loudly and specifically otherwise.
project_resolve_workspace() {
  local raw="$1" abs
  if [ -z "$raw" ]; then
    echo "error: empty workspace path" >&2
    return 1
  fi
  if [ ! -e "$raw" ]; then
    echo "error: path does not exist: $raw" >&2
    return 1
  fi
  if [ ! -d "$raw" ]; then
    echo "error: not a directory: $raw" >&2
    return 1
  fi
  abs="$(cd "$raw" && pwd)"
  if [ ! -r "$abs" ]; then
    echo "error: directory is not readable: $abs" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

project_is_git_repo() {
  local dir="$1"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

project_git_status() {
  local dir="$1"
  git -C "$dir" status --porcelain=v1
}

# `git diff HEAD` alone misses brand-new (untracked) files entirely — a very
# real case, since Claude Code creating a new file is at least as common as
# editing an existing one. `add -A -N` (intent-to-add) marks new paths for
# tracking without staging their content, which is what makes them show up
# in an ordinary diff as an addition; it never touches the working tree and
# is trivially reversible (`git reset`), so we just do it before every diff.
project_git_mark_new_files() {
  local dir="$1"
  git -C "$dir" add -A -N >/dev/null 2>&1 || true
}

project_git_diff() {
  local dir="$1"
  project_git_mark_new_files "$dir"
  # Includes both staged and unstaged changes against HEAD; falls back to
  # diffing against the empty tree for a repo with no commits yet.
  if git -C "$dir" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$dir" diff HEAD
  else
    git -C "$dir" diff --cached
  fi
}

project_git_changed_files() {
  local dir="$1"
  project_git_mark_new_files "$dir"
  if git -C "$dir" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$dir" diff --name-only HEAD
  else
    git -C "$dir" diff --cached --name-only
  fi
}

# Prints one ecosystem tag per line: node, python, make. Empty output means
# unknown/unhandled ecosystem (P0 only supports these three).
project_detect_ecosystem() {
  local dir="$1"
  [ -f "$dir/package.json" ] && echo "node"
  [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/requirements.txt" ] && echo "python"
  [ -f "$dir/Makefile" ] && echo "make"
  return 0
}

# True if the only changed files are documentation/comments-only by
# extension heuristic. Used for the P0.9 "skip review" rule. Deliberately
# simple: any non-markdown/non-txt path changed means "not trivial".
project_changes_are_docs_only() {
  local dir="$1" f any=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    any=1
    case "$f" in
      *.md|*.mdx|*.txt|LICENSE|CHANGELOG*|docs/*) ;;
      *) return 1 ;;
    esac
  done < <(project_git_changed_files "$dir")
  [ "$any" -eq 1 ]
}
