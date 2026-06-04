#!/usr/bin/env bash

set -euo pipefail

ORIGINAL_PWD="$PWD"
TARGET_DIR="target/manifests"
WORKTREE_ROOT_DIR="target/worktrees"

COMMIT_ISH=""
FORWARD_ARGS=()

parse_args() {
	while [[ "$#" -gt 0 ]]; do
		case $1 in
		-c | --commit-ish)
			if [[ -n "${2:-}" && "$2" != -* ]]; then
				COMMIT_ISH="$2"
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		-t | --target-dir)
			if [[ -n "${2:-}" && "$2" != -* ]]; then
				TARGET_DIR="$2"
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		*)
			# Keep all other args to pass through to the kustomize-build script
			FORWARD_ARGS+=("$1")
			shift
			;;
		esac
	done

	if [[ -z "$GIT_REF" ]]; then
		echo "Error: --ref <git-ref> is required." >&2
		return 1
	fi

	return 0
}

cleanup() {
	# Step out of the worktree back to the original directory before deleting
	cd "$ORIGINAL_PWD" || true
	if [[ -n "$WORKTREE_DIR" && -d "$WORKTREE_DIR" ]]; then
		git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
	fi
}

main() {
	if ! parse_args "$@"; then
		return 1
	fi

	local safe_ref=$(echo "$GIT_REF" | tr '/\' '_')
	local build_script="$(realpath "$(dirname "$0")/kustomize-build.sh")"
	local abs_target_dir=$(realpath "$TARGET_DIR")

	WORKTREE_DIR="$ORIGINAL_PWD/$WORKTREE_ROOT_DIR/$safe_ref"
	trap cleanup EXIT

	# Create a worktree to cheaply build the manifests from the given git ref
	if ! git worktree add --detach "$WORKTREE_DIR" "$GIT_REF" >/dev/null 2>&1; then
		echo "Error: Failed to create git worktree for ref '$GIT_REF'." >&2
		return 1
	fi

	cd "$WORKTREE_DIR"
	"$build_script" -t "$new_target_dir" "${FORWARD_ARGS[@]}"
}

main "$@"
