#!/usr/bin/env bash
#
# Render every kustomize overlay on the base branch and on the PR head, then
# emit a Markdown report of the overlays whose rendered output changed.
#
# An "overlay" is any directory that is an immediate child of a directory named
# "overlays" and that contains a kustomization.yaml. Rendering the full overlay
# (rather than diffing changed files) means transitive changes — e.g. an edit to
# a shared base/ or components/ dir — show up against every overlay they affect.
#
# Diffs are produced with dyff, which compares the manifests semantically:
# resources are matched by kind/name/namespace, so document reordering and key
# ordering never show up as spurious changes. dyff cannot compare streams with a
# differing document count when it can't key the documents (notably a set of
# same-kind resources, or one side rendering empty); those cases fall back to a
# plain `diff -u` so a real change is never silently dropped.
#
# Usage: kustomize-overlay-diff.sh <base-tree> <head-tree> <output.md>
set -euo pipefail

prog="$(basename "$0")"

# Print usage. Writes to stdout for an explicit --help, stderr otherwise so it
# doesn't pollute a piped result; the caller chooses the exit code.
usage() {
  cat <<EOF
Usage: $prog <base-tree> <head-tree> <output.md>

Render every kustomize overlay found in each tree and write a Markdown report
of the overlays whose rendered output differs between them.

Arguments:
  base-tree    Path to the checkout to compare against (e.g. the target branch).
  head-tree    Path to the checkout under review (e.g. the PR head).
  output.md    File to write the Markdown report to (overwritten if it exists).

Environment:
  MAX_DIFF_LINES   Truncate each overlay's diff block to this many lines
                   (default: 400) to stay under GitHub's comment size limit.

Requires kustomize and dyff on PATH.
EOF
}

# Show full help on request, before any argument validation.
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

if [ "$#" -ne 3 ]; then
  echo "$prog: error: expected 3 arguments, got $#." >&2
  echo >&2
  usage >&2
  exit 2
fi

BASE_DIR="$1"
HEAD_DIR="$2"
OUT="$3"

# Cap each block so one huge overlay can't blow past GitHub's comment size limit.
MAX_DIFF_LINES="${MAX_DIFF_LINES:-400}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

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

# Render an overlay; manifests to $1, stderr to $1.err. Returns kustomize's rc.
render() {
  local out="$1" root="$2" overlay="$3"
  kustomize build "$root/$overlay" >"$out" 2>"$out.err"
}

# Truncate text on stdin to MAX_DIFF_LINES, appending a note if it was clipped.
truncate_block() {
  local total; total="$(wc -l <"$1")"
  if [ "$total" -gt "$MAX_DIFF_LINES" ]; then
    head -n "$MAX_DIFF_LINES" "$1"
    printf '\n... truncated (%s lines total) — render locally with `kustomize build`.\n' "$total"
  else
    cat "$1"
  fi
}

# Build the union of overlay paths present on either branch.
mapfile -t overlays < <( { list_overlays "$BASE_DIR"; list_overlays "$HEAD_DIR"; } | sort -u )

changed=()        # markdown blocks, one per changed overlay
summary_rows=()   # rows for the summary table

for overlay in "${overlays[@]}"; do
  base_present=false; head_present=false
  [ -f "$BASE_DIR/$overlay/kustomization.yaml" ] && base_present=true
  [ -f "$HEAD_DIR/$overlay/kustomization.yaml" ] && head_present=true

  base_out="$workdir/base.yaml"; : >"$base_out"; : >"$base_out.err"
  head_out="$workdir/head.yaml"; : >"$head_out"; : >"$head_out.err"
  base_rc=0; head_rc=0
  $base_present && { render "$base_out" "$BASE_DIR" "$overlay" || base_rc=$?; }
  $head_present && { render "$head_out" "$HEAD_DIR" "$overlay" || head_rc=$?; }

  # A build error on the PR head is always worth reporting, loudly.
  if $head_present && [ "$head_rc" -ne 0 ]; then
    summary_rows+=("| \`$overlay\` | 🛑 build failed |")
    changed+=("$(printf '<details open><summary>🛑 <code>%s</code> — kustomize build failed</summary>\n\n```\n%s\n```\n\n</details>' \
      "$overlay" "$(cat "$head_out.err")")")
    continue
  fi

  body_file="$workdir/body.txt"
  if ! $base_present && $head_present; then
    icon="🟢"; label="new overlay"; fence="yaml"
    cp "$head_out" "$body_file"
  elif $base_present && ! $head_present; then
    icon="🔴"; label="overlay removed"; fence="yaml"
    cp "$base_out" "$body_file"
  else
    # Both present (base build failures are surfaced inside the diff via dyff/diff).
    dyff_rc=0
    dyff between --set-exit-code --omit-header --output github \
      "$base_out" "$head_out" >"$body_file" 2>"$workdir/dyff.err" || dyff_rc=$?
    case "$dyff_rc" in
      0) continue ;;                  # semantically identical — nothing to report
      1) icon="🟡"; label="modified"; fence="diff" ;;
      *)                              # dyff couldn't compare — fall back to textual diff
        icon="🟡"; label="modified (textual diff — dyff unavailable)"; fence="diff"
        diff -u "$base_out" "$head_out" \
          --label "a/$overlay" --label "b/$overlay" >"$body_file" || true
        ;;
    esac
  fi

  summary_rows+=("| \`$overlay\` | $icon $label |")
  changed+=("$(printf '<details><summary>%s <code>%s</code> — %s</summary>\n\n```%s\n%s\n```\n\n</details>' \
    "$icon" "$overlay" "$label" "$fence" "$(truncate_block "$body_file")")")
done

# Assemble the report.
{
  echo '<!-- kustomize-overlay-diff -->'
  echo '## 🧬 Kustomize overlay diff'
  echo
  if [ "${#changed[@]}" -eq 0 ]; then
    echo '✅ No rendered changes in any kustomize overlay.'
    echo
    printf '_Compared %d overlay(s) against the base branch with dyff._\n' "${#overlays[@]}"
  else
    printf '%d of %d overlay(s) changed:\n\n' "${#changed[@]}" "${#overlays[@]}"
    echo '| Overlay | Status |'
    echo '| --- | --- |'
    printf '%s\n' "${summary_rows[@]}"
    echo
    printf '%s\n\n' "${changed[@]}"
  fi
} >"$OUT"

echo "Wrote report for ${#overlays[@]} overlay(s), ${#changed[@]} changed, to $OUT"
