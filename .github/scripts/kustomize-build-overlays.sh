#!/usr/bin/env bash
#
# Render every kustomize overlay in a source tree into an output directory, so a
# later step can diff two such directories without re-running kustomize.
#
# An "overlay" is any directory that is an immediate child of a directory named
# "overlays" and that contains a kustomization.yaml.
#
# For each overlay found, this writes three files under <output-dir>, mirroring
# the overlay's path within the source tree:
#
#   <output-dir>/<overlay>/manifest.yaml   rendered manifests (kustomize stdout)
#   <output-dir>/<overlay>/stderr          kustomize stderr (empty on success)
#   <output-dir>/<overlay>/status          kustomize exit code
#
# A build failure is recorded (non-zero status) rather than aborting the run, so
# the diff step can report it; this command still exits 0 in that case.
#
# Usage: kustomize-build-overlays.sh <source-tree> <output-dir>
set -euo pipefail

prog="$(basename "$0")"

# Print usage. Writes to stdout for an explicit --help, stderr otherwise so it
# doesn't pollute a piped result; the caller chooses the exit code.
usage() {
  cat <<EOF
Usage: $prog <source-tree> <output-dir>

Render every kustomize overlay found in <source-tree> into <output-dir>. For
each overlay a directory mirroring its path is created containing manifest.yaml
(rendered output), stderr, and status (the kustomize exit code).

Arguments:
  source-tree   Path to the checkout whose overlays should be rendered.
  output-dir    Directory to write rendered overlays into (created if needed).

Requires kustomize on PATH.
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
OUT="$2"

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
