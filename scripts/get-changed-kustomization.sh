#!/usr/bin/env bash

# Enforce strict error handling
set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(realpath "$0" 2>/dev/null || echo ".")")
readonly DEPS_CMD="$SCRIPT_DIR/kustomize-deps.sh"
source "$SCRIPT_DIR/check-cli-tools.sh"

GIT_REF="origin/HEAD"
DIRS=()

usage() {
	echo "Usage: $0 [--ref <git-ref>] <kustomize-dir>..." >&2
	exit 1
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ref)
			if [[ -n "${2:-}" ]]; then
				GIT_REF="$2"
				shift 2
			else
				echo "Error: --ref requires a git reference argument." >&2
				usage
			fi
			;;
		-*)
			echo "Error: Unknown flag $1" >&2
			usage
			;;
		*)
			DIRS+=("$1")
			shift
			;;
		esac
	done

	# Ensure at least one directory was provided
	if [[ ${#DIRS[@]} -eq 0 ]]; then
		usage
	fi
}

find_changed_kustomizations() {
	local target_dirs=("$@")
	# --no-renames: with rename detection on (git's default), a deleted overlay's
	# kustomization.yaml can get paired up with an added file elsewhere and reported
	# as a rename instead of a delete, which would drop it from --name-only output
	# entirely and hide the deletion from both loops below.
	local changed_files=$(git diff --no-renames --name-only --relative "$GIT_REF" | sort -u)

	# If no files have changed in the repo, exit cleanly immediately
	if [[ -z "$changed_files" ]]; then
		exit 0
	fi

	declare -A changed_overlays

	# Shortcut some of the processing if any of the direct overlay kustomizations have been changed.
	# This has the added benefit circumventing the need to process all the globs/overlays in the
	# target ref as well in order to pick up on deleted overlays. --no-renames (see above) is what
	# makes deleted overlays actually show up here rather than being folded into a rename.
	#
	# :(glob) is required here: git's default pathspec matching lets a bare '*' cross '/'
	# (e.g. 'a/*/kustomization.yaml' matches 'a/b/c/kustomization.yaml'), unlike the shell
	# globbing used below for the same target_dirs patterns. Without it, this shortcut could
	# report a directory nested deeper than the intended overlay dir as "changed".
	local kustomization_pathspecs=()
	for dir in "${target_dirs[@]}"; do
		kustomization_pathspecs+=(":(glob)$dir/kustomization.yaml" ":(glob)$dir/kustomization.yml")
	done
	while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      changed_overlays["$(dirname "$file")"]=1
  done < <(git diff --no-renames --name-only --relative "$GIT_REF" "${kustomization_pathspecs[@]}")

	# manually expand any globs given on cmd line
	shopt -s nullglob
	expanded_files=( ${target_dirs[@]} )
	shopt -u nullglob

	for dir in "${expanded_files[@]}"; do
		if [[ -n "${changed_overlays["$dir"]+isset}" ]]; then
			continue
		fi

		if [[ ! -d "$dir" ]]; then
			echo "Warning: '$dir' is not a directory, or does not exist. Skipping." >&2
			continue
		fi

		# Split declaration from assignment: `local kust_files=$(...)` would discard
		# the command substitution's exit status (the `local` builtin's own success
		# is what `set -e` sees instead), silently hiding a real failure here as
		# "this overlay has no dependencies" instead of failing the change check.
		local kust_files
		if ! kust_files=$("$DEPS_CMD" "$dir" | sort -u); then
			echo "Error: '$DEPS_CMD' failed for '$dir'." >&2
			exit 1
		fi
		if [[ -z "$kust_files" ]]; then
			continue
		fi

		# Only get files that are in both the kustomize file list and the git diff list
		# Print the kustomization directory if any files were found to have changed
		local overlap=$(comm -12 <(echo "$changed_files") <(echo "$kust_files"))
		if [[ -n "$overlap" ]]; then
			changed_overlays["$dir"]=1
		fi
	done

	printf "%s\n" "${!changed_overlays[@]}"
}

main() {
	check_cli_tools yq

	parse_args "$@"

	# Verify we are inside a Git repository
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		echo "Error: This command must be run inside a git repository." >&2
		exit 1
	fi

	# Verify the git ref exists
	if ! git rev-parse --verify "$GIT_REF" &>/dev/null; then
		echo "Error: Invalid git ref '$GIT_REF'." >&2
		exit 1
	fi

	find_changed_kustomizations "${DIRS[@]}"
}

main "$@"
