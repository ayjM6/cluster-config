#!/usr/bin/env bash

# Enforce strict error handling
set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(realpath "$0" 2>/dev/null || echo ".")")
readonly DEPS_CMD="$SCRIPT_DIR/kustomize-deps.sh"

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
	local changed_files=$(git diff --name-only --relative "$GIT_REF" | sort -u)

	# If no files have changed in the repo, exit cleanly immediately
	if [[ -z "$changed_files" ]]; then
		exit 0
	fi

	for dir in "${target_dirs[@]}"; do
		if [[ ! -d "$dir" ]]; then
			echo "Warning: '$dir' is not a directory, or does not exist. Skipping." >&2
			continue
		fi

		local kust_files=$("$DEPS_CMD" "$dir" 2>/dev/null | sort -u)
		if [[ -z "$kust_files" ]]; then
			continue
		fi

		# Only get files that are in both the kustomize file list and the git diff list
		# Print the kustomization directory if any files were found to have changed
		local overlap=$(comm -12 <(echo "$changed_files") <(echo "$kust_files"))
		if [[ -n "$overlap" ]]; then
			echo "$dir"
		fi
	done
}

main() {
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
