#!/usr/bin/env bash

set -euo pipefail

TARGET_DIR="target/manifests"
ROOT_DIR="$PWD"
BUILD_DIRS=()
KUSTOMIZE_ARGS=()

parse_args() {
	while [[ "$#" -gt 0 ]]; do
		case $1 in
		-t | --target-dir)
			if [[ -n "$2" && "$2" != -* ]]; then
				TARGET_DIR="$2"
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				return 1
			fi
			;;
		-r | --root-dir)
			if [[ -n "$2" && "$2" != -* ]]; then
				ROOT_DIR="$2"
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
		-h | --help)
			echo "Usage: $0 [-o <out-dir>] [-r <root-dir>] [-k <arg>] [directories...]"
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

	# Default to build current directory
	if [[ ${#BUILD_DIRS[@]} -eq 0 ]]; then
		BUILD_DIRS=(".")
	fi

	return 0
}

kustomize_build() {
	local kustomize_dir="$1"
	local root_dir="$2"
	local target_dir="$3"

	local abs_kustomize_dir=$(realpath "$kustomize_dir")

	# Ensure that the kustomize directory is a subdirectory of the root dir
	if [[ "$abs_kustomize_dir" == "$root_dir" || "$abs_kustomize_dir" != "$root_dir/"* ]]; then
		echo "Error: Directory '$kustomize_dir' is not contained within the root directory ($root_dir)." >&2
		return 1
	fi

	# Get the relative path to the kustomize dir from the root dir, so we can keep the
	# structure of the output identical to the structure relative to the root dir.
	local rel_kustomize_dir="${abs_kustomize_dir#$root_dir/}"
	local out_dir="$target_dir/$rel_kustomize_dir"
	local manifest_file="$out_dir/manifests.yaml"
	local stderr_file="$out_dir/stderr"
	mkdir -p "$out_dir"

	if kustomize build "${KUSTOMIZE_ARGS[@]}" "$kustomize_dir" -o "$manifest_file" 2>"$stderr_file"; then
		echo "[ ✓ ] $kustomize_dir"
		return 0
	else
		echo "[ ✗ ] $kustomize_dir"
		cat "$stderr_file" >&2
		return 1
	fi
}

kustomize_build_all() {
	local abs_root=$(realpath "$ROOT_DIR")
	local abs_out_dir=$(realpath "$TARGET_DIR")

	echo "--- Starting Kustomize Build ---"
	echo "Root Directory   : $ROOT_DIR"
	echo "Output Directory : $TARGET_DIR"
	echo "Kustomize Args   : ${KUSTOMIZE_ARGS[*]}"
	echo "Target Dirs      : ${BUILD_DIRS[*]}"
	echo "--------------------------------"

	local build_failed=0
	local failed_dirs=()
	for kustomize_dir in "${BUILD_DIRS[@]}"; do
		if ! kustomize_build "$kustomize_dir" "$abs_root" "$abs_out_dir"; then
			build_failed=1
			failed_dirs+=("$kustomize_dir")
		fi
	done
	echo "--------------------------------"

	# Check if any builds failed
	if [[ $build_failed -ne 0 ]]; then
		echo "Build completed with errors in the following directories:" >&2
		for dir in "${failed_dirs[@]}"; do
			echo "  - $dir" >&2
		done
		return 1
	else
		echo "Build process completed successfully."
		return 0
	fi
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

	kustomize_build_all
}

main "$@"
