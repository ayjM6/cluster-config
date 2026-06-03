#!/usr/bin/env bash
#
# Render every kustomize overlay of a SINGLE revision of the repository into the
# main repository's top-level target/ directory, so a later step can diff two
# revisions without re-running kustomize.
#
# This builds exactly one revision per call: whatever is checked out in
# <source-tree>. To compare two revisions, call this once per revision — e.g.
# once for the current checkout and once for another ref checked out in a
# separate git worktree — giving each a distinct <name>.
#
# Output always lands under the *main* repository's target/ directory, even when
# <source-tree> is a linked worktree, so both calls collect their results in one
# place. For each overlay, mirroring its path within the source tree:
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
# Usage: kustomize-build-overlays.sh <source-tree> <name>
set -euo pipefail

prog="$(basename "$0")"

# Print usage. Writes to stdout for an explicit --help, stderr otherwise so it
# doesn't pollute a piped result; the caller chooses the exit code.
usage() {
  cat <<EOF
Usage: $prog <source-tree> <name>

Render every kustomize overlay of the revision checked out in <source-tree> into
<main-repo>/target/<name>, where <main-repo> is the top level of the main git
repository (resolved even when <source-tree> is a linked worktree). For each
overlay a directory mirroring its path is created containing manifest.yaml
(rendered output), stderr, and status (the kustomize exit code).

Call once per revision (e.g. once for the current checkout, once for another ref
in a separate worktree), giving each a distinct <name>.

Arguments:
  source-tree   Path to the checkout/worktree whose overlays should be rendered.
  name          Subdirectory of target/ to write this revision's output into
                (e.g. "base" or "head"; letters, digits, ., _ and - only).

Requires kustomize and git on PATH.
EOF
}

# Show full help on request, before any argument validation.
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 2 ]; then
  echo "$prog: error: expected 2 arguments, got $#." >&2
  echo >&2
  usage >&2
  exit 2
fi

SRC="$1"
NAME="$2"

if [ ! -d "$SRC" ]; then
  echo "$prog: error: source tree '$SRC' is not a directory." >&2
  exit 2
fi
if ! [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "$prog: error: name '$NAME' must contain only letters, digits, '.', '_' or '-'." >&2
  exit 2
fi

# Resolve the main repository's top level from the source tree. --git-common-dir
# points at the main repo's .git even from a linked worktree, so its parent is
# the main working tree — meaning every call writes into the same target/.
common_dir="$(git -C "$SRC" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
  echo "$prog: error: '$SRC' is not inside a git repository." >&2
  exit 2
}
main_root="$(dirname "$common_dir")"
OUT="$main_root/target/$NAME"

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

echo "Built $count overlay(s) from $SRC into $OUT ($failed failed)."
