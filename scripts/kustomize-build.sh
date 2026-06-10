#!/usr/bin/env bash

set -euo pipefail

ORIGINAL_PWD="$PWD"
TARGET_DIR="target/manifests"
WORKTREE_ROOT_DIR="target/worktrees"
GIT_REF=""
SKIP_MISSING=0

BUILD_DIRS=()
KUSTOMIZE_ARGS=()

parse_args() {
	while [[ "$#" -gt 0 ]]; do
		case $1 in
		--ref)
			if [[ -n "$2" && "$2" != -* ]]; then
				GIT_REF="$2"
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		-t | --target-dir)
			if [[ -n "$2" && "$2" != -* ]]; then
				TARGET_DIR="$2"
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		-k | --kustomize-arg)
			if [[ -n "$2" ]]; then
				KUSTOMIZE_ARGS+=("$2")
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		--skip-missing)
			SKIP_MISSING=1
			shift
			;;
		-h | --help)
			echo "Usage: $0 [-o <out-dir>] [-k <arg>] [directories...]"
			exit 0
			;;
		--)
			shift
			while [[ "$#" -gt 0 ]]; do
				BUILD_DIRS+=("$1")
				shift
			done
			break
			;;
		-*)
			echo "Error: Unknown parameter passed: $1" >&2
			return 1
			;;
		*)
			BUILD_DIRS+=("$1")
			shift
			;;
		esac
	done

	# Handle args piped via stdin
	if [[ ! -t 0 ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			if [[ -n "$line" ]]; then
				BUILD_DIRS+=("$line")
			fi
		done
	fi

	# Default to build current directory
	if [[ ${#BUILD_DIRS[@]} -eq 0 ]]; then
		BUILD_DIRS=(".")
	fi

	return 0
}

kustomize_build() {
	local kustomize_dir="$1"
	local target_dir="$2"

	local abs_kustomize_dir=$(realpath "$kustomize_dir")
	local abs_pwd=$(realpath "$PWD")

	# Ensure that the kustomize directory is a subdirectory of the current directory
	if [[ "$abs_kustomize_dir" == "$abs_pwd" || "$abs_kustomize_dir" != "$abs_pwd/"* ]]; then
		echo "Error: Directory '$kustomize_dir' is not contained within the working directory ($abs_pwd)." >&2
		return 1
	fi

	# Get the relative path to the kustomize dir from the working dir
	local rel_kustomize_dir="${abs_kustomize_dir#$abs_pwd/}"
	local out_dir="$target_dir/$rel_kustomize_dir"
	local manifest_file="$out_dir/manifests.yaml"
	local stderr_file="$out_dir/stderr"
	mkdir -p "$out_dir"

	if [[ "$SKIP_MISSING" -eq 1  && ! -d "$kustomize_dir" ]]; then
		echo "[ ➖ ] $kustomize_dir"
		return 0
	elif kustomize build "${KUSTOMIZE_ARGS[@]}" "$kustomize_dir" -o "$manifest_file" 2>"$stderr_file"; then
		echo "[ ✅ ] $kustomize_dir"
		return 0
	else
		echo "[ ❌ ] $kustomize_dir"
		cat "$stderr_file" >&2
		return 1
	fi
}

kustomize_build_all() {
	local out_dir="$1"
	local abs_pwd=$(realpath "$PWD")

	echo "---------------------------  Kustomize Build ---------------------------"
	echo "Output Directory : ${TARGET_DIR}"
	if [[ ${#KUSTOMIZE_ARGS[@]} -gt 0 ]]; then
		echo "Kustomize Args   : ${KUSTOMIZE_ARGS[@]}"
	fi
	echo "------------------------------------------------------------------------"

	local build_failed=0
	local failed_dirs=()
	for kustomize_dir in "${BUILD_DIRS[@]}"; do
		if ! kustomize_build "$kustomize_dir" "$out_dir"; then
			build_failed=1
			failed_dirs+=("$kustomize_dir")
		fi
	done
	echo "------------------------------------------------------------------------"

	# Check if any builds failed
	if [[ $build_failed -ne 0 ]]; then
		echo "BUILD FAILED with errors in the following directories:" >&2
		for dir in "${failed_dirs[@]}"; do
			echo "  - $dir" >&2
		done
		return 1
	else
		echo "BUILD SUCCESSFUL"
		return 0
	fi
}

cleanup() {
	# Step out of the worktree back to the original directory before deleting
	cd "$ORIGINAL_PWD" || true
	if [[ -n "$WORKTREE_DIR" && -d "$WORKTREE_DIR" ]]; then
		git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
	fi
}

setup_worktree() {
	# make sure we're running at the root of the git repository if working with worktrees
	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "Error: Not inside a Git repository." >&2
		exit 1
	fi

	if [[ -n "$(git rev-parse --show-cdup)" ]]; then
		echo "Error: This script must be run from the root of the Git repository." >&2
		exit 1
	fi

	trap cleanup EXIT

	local safe_ref=$(echo "$GIT_REF" | tr '/\\' '_')
	WORKTREE_DIR="$ORIGINAL_PWD/$WORKTREE_ROOT_DIR/$safe_ref"

	if ! git worktree add --detach "$WORKTREE_DIR" "$GIT_REF" >/dev/null 2>&1; then
		echo "Error: Failed to create git worktree for ref '$GIT_REF'." >&2
		return 1
	fi

	cd "$WORKTREE_DIR"
}

main() {
	if ! parse_args "$@"; then
		return 1
	fi

	if ! command -v kustomize &>/dev/null; then
		echo "Error: kustomize is not installed or not in your PATH." >&2
		exit 1
	fi

	if ! command -v realpath &>/dev/null; then
		echo "Error: realpath command is required but not found in your PATH." >&2
		exit 1
	fi

	# set abs path for target dir, before we potentially switch dirs when
	# setting up the worktree
	mkdir -p "$TARGET_DIR"
	abs_target_dir="$(realpath "$TARGET_DIR")"

	if [[ -n "$GIT_REF" ]]; then
		setup_worktree || exit 1
	fi
	kustomize_build_all "$abs_target_dir"
}

main "$@"
