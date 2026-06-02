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
# Usage: kustomize-overlay-diff.sh <base-tree> <head-tree> <output.md>
set -euo pipefail

BASE_DIR="${1:?usage: kustomize-overlay-diff.sh <base-tree> <head-tree> <output.md>}"
HEAD_DIR="${2:?missing head tree}"
OUT="${3:?missing output file}"

# Cap each diff so one huge overlay can't blow past GitHub's comment size limit.
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

# Render an overlay from a tree into $1 (stdout file). Returns kustomize's exit
# code; on failure the stderr is left in $1 so the report can show the error.
render() {
  local out="$1" root="$2" overlay="$3"
  kustomize build "$root/$overlay" >"$out" 2>"$out.err"
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

  if $base_present; then render "$base_out" "$BASE_DIR" "$overlay" || base_rc=$?; fi
  if $head_present; then render "$head_out" "$HEAD_DIR" "$overlay" || head_rc=$?; fi

  # A build error on the PR head is always worth reporting.
  if $head_present && [ "$head_rc" -ne 0 ]; then
    summary_rows+=("| \`$overlay\` | 🛑 build failed |")
    err="$(cat "$head_out.err")"
    changed+=("$(printf '<details open><summary>🛑 <code>%s</code> — kustomize build failed</summary>\n\n```\n%s\n```\n\n</details>' \
      "$overlay" "$err")")
    continue
  fi

  # Classify the change.
  local_status=""
  if ! $base_present && $head_present; then
    local_status="added"
  elif $base_present && ! $head_present; then
    local_status="removed"
  elif cmp -s "$base_out" "$head_out"; then
    continue   # rendered output identical — nothing to report
  else
    local_status="modified"
  fi

  # Produce a unified diff (diff exits 1 when files differ — that's expected).
  diff_text="$(diff -u "$base_out" "$head_out" \
    --label "a/$overlay (base)" --label "b/$overlay (head)" || true)"

  total_lines="$(printf '%s\n' "$diff_text" | wc -l)"
  truncated=""
  if [ "$total_lines" -gt "$MAX_DIFF_LINES" ]; then
    diff_text="$(printf '%s\n' "$diff_text" | head -n "$MAX_DIFF_LINES")"
    truncated=$'\n... diff truncated ('"$total_lines"$' lines total) — render locally with `kustomize build` to see the full output.'
  fi

  case "$local_status" in
    added)    icon="🟢"; label="new overlay" ;;
    removed)  icon="🔴"; label="overlay removed" ;;
    modified) icon="🟡"; label="modified" ;;
  esac

  summary_rows+=("| \`$overlay\` | $icon $label |")
  changed+=("$(printf '<details><summary>%s <code>%s</code> — %s</summary>\n\n```diff\n%s%s\n```\n\n</details>' \
    "$icon" "$overlay" "$label" "$diff_text" "$truncated")")
done

# Assemble the report.
{
  echo '<!-- kustomize-overlay-diff -->'
  echo '## 🧬 Kustomize overlay diff'
  echo
  if [ "${#changed[@]}" -eq 0 ]; then
    echo '✅ No rendered changes in any kustomize overlay.'
    echo
    printf '_Compared %d overlay(s) against the base branch._\n' "${#overlays[@]}"
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
