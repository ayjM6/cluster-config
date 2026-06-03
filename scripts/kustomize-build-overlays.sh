#!/usr/bin/env bash
#
# Render every kustomize overlay of a SINGLE revision of the repository into the
# main repository's top-level target/ directory, so a later step can diff two
# revisions without re-running kustomize.
#
# By default the current working tree is built — no worktrees are created. Pass
# --revision <revision> to instead build a specific git revision: a detached
# worktree is created for it, its overlays are rendered, and the worktree is
# removed again before the command returns.
#
# Either way the output lands under the *main* repository's target/ directory,
# in the subdirectory named by <name>. For each overlay, mirroring its path:
#
#   <main-repo>/target/<name>/<overlay>/manifest.yaml   rendered manifests
#   <main-repo>/target/<name>/<overlay>/stderr          kustomize stderr
#   <main-repo>/target/<name>/<overlay>/status          kustomize exit code
#
# An "overlay" is any directory that is an immediate child of a directory named
# "overlays" and that contains a kustomization.yaml. A build failure is recorded
# (non-zero status) rather than aborting the run, so the diff step can report it;
# this command still exits 0 in that case.
#
# Usage: kustomize-build-overlays.sh [--revision <revision>] <name>
set -euo pipefail

prog="$(basename "$0")"

# Print usage. Writes to stdout for an explicit --help, stderr otherwise so it
# doesn't pollute a piped result; the caller chooses the exit code.
usage() {
  cat <<EOF
Usage: $prog [--revision <revision>] <name>

Render every kustomize overlay of a single revision into <main-repo>/target/<name>,
where <main-repo> is the top level of the main git repository. For each overlay a
directory mirroring its path is created containing manifest.yaml (rendered
output), stderr, and status (the kustomize exit code).

Options:
  --revision <rev>   Build this git revision (branch, tag or commit) in a
                     temporary detached worktree that is removed afterwards.
                     When omitted, the current working tree is built directly
                     and no worktree is created.

Arguments:
  name               Subdirectory of target/ to write this revision's output
                     into (e.g. "base" or "head"; letters, digits, ., _ and -).

Requires kustomize and git on PATH.
EOF
}

revision=""
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --revision)
      [ "$#" -ge 2 ] || { echo "$prog: error: --revision requires a value." >&2; exit 2; }
      revision="$2"
      shift 2
      ;;
    --revision=*)
      revision="${1#--revision=}"
      shift
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done
      ;;
    -*)
      echo "$prog: error: unknown option '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [ "${#positional[@]}" -ne 1 ]; then
  echo "$prog: error: expected a single <name> argument, got ${#positional[@]}." >&2
  echo >&2
  usage >&2
  exit 2
fi
NAME="${positional[0]}"

if ! [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "$prog: error: name '$NAME' must contain only letters, digits, '.', '_' or '-'." >&2
  exit 2
fi

# Resolve the main repository's top level from the current directory.
# --git-common-dir points at the main repo's .git even from a linked worktree, so
# its parent is the main working tree — every call writes into the same target/.
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "$prog: error: not inside a git repository." >&2
  exit 2
}
main_root="$(dirname "$common_dir")"
OUT="$main_root/target/$NAME"

# When building a specific revision, render it from a throwaway detached worktree
# and make sure that worktree is cleaned up however the script exits.
tmp_parent=""
worktree_dir=""
cleanup() {
  [ -n "$worktree_dir" ] && git -C "$main_root" worktree remove --force "$worktree_dir" 2>/dev/null || true
  [ -n "$tmp_parent" ] && rm -rf "$tmp_parent"
}

if [ -n "$revision" ]; then
  if ! git -C "$main_root" rev-parse --verify --quiet "${revision}^{commit}" >/dev/null; then
    echo "$prog: error: revision '$revision' not found." >&2
    exit 2
  fi
  trap cleanup EXIT
  tmp_parent="$(mktemp -d)"
  worktree_dir="$tmp_parent/worktree"
  git -C "$main_root" worktree add --detach "$worktree_dir" "$revision" >/dev/null
  SRC="$worktree_dir"
  src_label="revision $revision"
else
  SRC="$(git rev-parse --show-toplevel)"
  src_label="working tree $SRC"
fi

# List overlay directories (relative paths) found under a tree root.
list_overlays() {
  local root="$1"
  [ -d "$root" ] || return 0
  ( cd "$root" \
      && find . -type d -regextype posix-extended -regex '.*/overlays/[^/]+' \
           -exec test -f '{}/kustomization.yaml' ';' -print 2>/dev/null \
      | sed 's#^\./##' \
      | sort )
}

# Start from a clean slate so a removed overlay doesn't linger from a prior run.
rm -rf "$OUT"
mkdir -p "$OUT"

count=0
failed=0
while IFS= read -r overlay; do
  [ -n "$overlay" ] || continue
  dest="$OUT/$overlay"
  mkdir -p "$dest"
  rc=0
  kustomize build "$SRC/$overlay" >"$dest/manifest.yaml" 2>"$dest/stderr" || rc=$?
  printf '%s\n' "$rc" >"$dest/status"
  count=$((count + 1))
  [ "$rc" -ne 0 ] && failed=$((failed + 1))
done < <(list_overlays "$SRC")

echo "Built $count overlay(s) from $src_label into $OUT ($failed failed)."
