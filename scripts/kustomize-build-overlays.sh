#!/usr/bin/env bash
#
# Render every kustomize overlay of a SINGLE revision of the repository into an
# output directory, so a later step can diff two revisions without re-running
# kustomize.
#
# By default the current working tree is built — no worktrees are created. Pass
# --revision <revision> to instead build a specific git revision: a detached
# worktree is created for it, its overlays are rendered, and the worktree is
# removed again before the command returns.
#
# The output directory (--output-dir) is optional. When omitted it defaults,
# under the main repository's top level, to:
#
#   target/manifests/HEAD          when no revision is given
#   target/manifests/<revision>    when --revision <revision> is given
#
# Within the output directory, for each overlay (mirroring its path):
#
#   <output-dir>/<overlay>/manifest.yaml   rendered manifests
#   <output-dir>/<overlay>/stderr          kustomize stderr
#   <output-dir>/<overlay>/status          kustomize exit code
#
# An "overlay" is any directory that is an immediate child of a directory named
# "overlays" and that contains a kustomization.yaml. A build failure is recorded
# (non-zero status) rather than aborting the run, so the diff step can report it;
# this command still exits 0 in that case.
#
# Usage: kustomize-build-overlays.sh [--revision <revision>] [--output-dir <dir>]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
repo_dir="$(dirname "$script_dir")"

prog="$(basename "$0")"

# Print usage. Writes to stdout for an explicit --help, stderr otherwise so it
# doesn't pollute a piped result; the caller chooses the exit code.
usage() {
  cat <<EOF
Usage: $prog [--revision <revision>] [--output-dir <dir>]

Render every kustomize overlay of a single revision into an output directory.
For each overlay a directory mirroring its path is created containing
manifest.yaml (rendered output), stderr, and status (the kustomize exit code).

Options:
  --revision <rev>     Build this git revision (branch, tag or commit) in a
                       temporary detached worktree that is removed afterwards.
                       When omitted, the current working tree is built directly
                       and no worktree is created.
  -o, --output-dir <dir>
                       Directory to render into. Its contents are replaced on
                       each run. Defaults, under the main repository's top level,
                       to target/manifests/HEAD (no revision) or
                       target/manifests/<revision> (with --revision).

Requires kustomize and git on PATH.
EOF
}

revision=""
output_dir=""
output_set=false
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
    -o | --output-dir)
      [ "$#" -ge 2 ] || { echo "$prog: error: --output-dir requires a value." >&2; exit 2; }
      output_dir="$2"
      output_set=true
      shift 2
      ;;
    --output-dir=*)
      output_dir="${1#--output-dir=}"
      output_set=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "$prog: error: unknown option '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "$prog: error: unexpected argument '$1' (set the output directory with --output-dir)." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  echo "$prog: error: unexpected argument '$1' (set the output directory with --output-dir)." >&2
  echo >&2
  usage >&2
  exit 2
fi

if $output_set && [ -z "$output_dir" ]; then
  echo "$prog: error: --output-dir requires a non-empty value." >&2
  exit 2
fi

# Output directory: explicit --output-dir if given, otherwise revision-aware default.
if $output_set; then
  OUT="$output_dir"
elif [ -n "$revision" ]; then
  OUT="$repo_dir/target/manifests/$revision"
else
  OUT="$repo_dir/target/manifests/HEAD"
fi

# When building a specific revision, render it from a throwaway detached worktree
# and make sure that worktree is cleaned up however the script exits.
tmp_parent=""
worktree_dir=""
cleanup() {
  [ -n "$worktree_dir" ] && git -C "$repo_dir" worktree remove --force "$worktree_dir" 2>/dev/null || true
  [ -n "$tmp_parent" ] && rm -rf "$tmp_parent"
}

if [ -n "$revision" ]; then
  if ! git -C "$repo_dir" rev-parse --verify --quiet "${revision}^{commit}" >/dev/null; then
    echo "$prog: error: revision '$revision' not found." >&2
    exit 2
  fi
  trap cleanup EXIT
  tmp_parent="$(mktemp -d)"
  worktree_dir="$tmp_parent/worktree"
  git -C "$repo_dir" worktree add --detach "$worktree_dir" "$revision" >/dev/null
  SRC="$worktree_dir"
  src_label="revision $revision"
else
  SRC="$repo_dir"
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
