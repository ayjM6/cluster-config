#!/usr/bin/env bash
#
# Compare two directories of rendered overlays (each produced by
# kustomize-build-overlays.sh) and emit a Markdown report of the overlays whose
# rendered output changed. This step never runs kustomize itself — it works
# purely from the rendered manifests, so building and diffing can be separate
# jobs (e.g. build base and head in parallel, then diff the two outputs).
#
# Diffs are produced with dyff, which compares the manifests semantically:
# resources are matched by kind/name/namespace, so document reordering and key
# ordering never show up as spurious changes. dyff cannot compare streams with a
# differing document count when it can't key the documents (notably a set of
# same-kind resources, or one side rendering empty); those cases fall back to a
# plain `diff -u` so a real change is never silently dropped.
#
# Usage: kustomize-diff-overlays.sh <base-build-dir> <head-build-dir> <output.md>
set -euo pipefail

prog="$(basename "$0")"

usage() {
	cat <<EOF
Usage: $prog <base-build-dir> <head-build-dir> <output.md>

Compare two directories of rendered overlays produced by
kustomize-build-overlays.sh and write a Markdown report of the overlays whose
rendered output differs between them.

Arguments:
  base-build-dir   Rendered overlays to compare against (e.g. the target branch).
  head-build-dir   Rendered overlays under review (e.g. the PR head).
  output.md        File to write the Markdown report to (overwritten if it exists).

Environment:
  MAX_DIFF_LINES   Truncate each overlay's diff block to this many lines
                   (default: 400) to stay under GitHub's comment size limit.

Requires dyff on PATH.
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

# List the overlays present in a build directory (those with a status file),
# as relative paths mirroring the original overlay layout.
list_built() {
	local dir="$1"
	[ -d "$dir" ] || return 0
	(cd "$dir" &&
		find . -type f -name status -printf '%h\n' 2>/dev/null |
		sed 's#^\./##' |
			sort)
}

# Truncate a file to MAX_DIFF_LINES, appending a note if it was clipped.
truncate_block() {
	local total
	total="$(wc -l <"$1")"
	if [ "$total" -gt "$MAX_DIFF_LINES" ]; then
		head -n "$MAX_DIFF_LINES" "$1"
		printf '\n... truncated (%s lines total) — render locally with `kustomize build`.\n' "$total"
	else
		cat "$1"
	fi
}

# Build the union of overlay paths present in either build directory.
mapfile -t overlays < <({
	list_built "$BASE_DIR"
	list_built "$HEAD_DIR"
} | sort -u)

changed=()      # markdown blocks, one per changed overlay
summary_rows=() # rows for the summary table

for overlay in "${overlays[@]}"; do
	base_present=false
	head_present=false
	[ -f "$BASE_DIR/$overlay/status" ] && base_present=true
	[ -f "$HEAD_DIR/$overlay/status" ] && head_present=true

	head_rc=0
	$head_present && head_rc="$(cat "$HEAD_DIR/$overlay/status")"

	# A build error on the PR head is always worth reporting, loudly.
	if $head_present && [ "$head_rc" -ne 0 ]; then
		summary_rows+=("| \`$overlay\` | 🛑 build failed |")
		changed+=("$(printf '<details open><summary>🛑 <code>%s</code> — kustomize build failed</summary>\n\n```\n%s\n```\n\n</details>' \
			"$overlay" "$(cat "$HEAD_DIR/$overlay/stderr")")")
		continue
	fi

	body_file="$workdir/body.txt"
	if ! $base_present && $head_present; then
		icon="🟢"
		label="new overlay"
		fence="yaml"
		truncate_block "$HEAD_DIR/$overlay/manifest.yaml" >"$body_file"
	elif $base_present && ! $head_present; then
		icon="🔴"
		label="overlay removed"
		fence="yaml"
		truncate_block "$BASE_DIR/$overlay/manifest.yaml" >"$body_file"
	else
		# Both present (base build failures are surfaced inside the diff via dyff/diff).
		base_manifest="$BASE_DIR/$overlay/manifest.yaml"
		head_manifest="$HEAD_DIR/$overlay/manifest.yaml"
		dyff_rc=0
		dyff between --set-exit-code --omit-header --output github \
			"$base_manifest" "$head_manifest" >"$workdir/raw.txt" 2>"$workdir/dyff.err" || dyff_rc=$?
		case "$dyff_rc" in
		0) continue ;; # semantically identical — nothing to report
		1)
			icon="🟡"
			label="modified"
			fence="diff"
			;;
		*) # dyff couldn't compare — fall back to textual diff
			icon="🟡"
			label="modified (textual diff — dyff unavailable)"
			fence="diff"
			diff -u "$base_manifest" "$head_manifest" \
				--label "a/$overlay" --label "b/$overlay" >"$workdir/raw.txt" || true
			;;
		esac
		truncate_block "$workdir/raw.txt" >"$body_file"
	fi

	summary_rows+=("| \`$overlay\` | $icon $label |")
	changed+=("$(printf '<details><summary>%s <code>%s</code> — %s</summary>\n\n```%s\n%s\n```\n\n</details>' \
		"$icon" "$overlay" "$label" "$fence" "$(cat "$body_file")")")
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
