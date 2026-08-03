#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(realpath "$0")")
source "$SCRIPT_DIR/check-cli-tools.sh"

TARGET_DIR="target/manifests"
BASE_DIR="."
SKIP_MISSING=0
VERBOSE=0

BUILD_DIRS=()
KUSTOMIZE_ARGS=()

usage() {
	cat << EOF
Usage: $(basename "$0") [OPTIONS] [--] [DIRECTORIES...]

Builds Kustomize manifests for specified directories and outputs them structurally into a target directory.

Options:
  -b, --base-dir DIR    Base directory that must contain all build directories (Default: ".")
  -t, --target-dir DIR  Directory where generated manifests will be saved (Default: "target/manifests")
  -s, --skip-missing    Skip build directories that do not exist instead of throwing an error
  -v, --verbose         Enable verbose logging output
  -h, --help            Display this help text and exit
  * Any other flags (e.g., --enable-helm) are passed straight to 'kustomize build'.

Arguments:
  --                    Explicitly separates options from positional directory arguments.
  DIRECTORIES           One or more directories to build. Defaults to "." if omitted.
                        Also accepts directory paths passed via stdin.

Examples:
  $(basename "$0") -b . -t ./dist environments/staging environments/production
  echo "environments/dev" | $(basename "$0") -v
EOF
}

parse_args() {
	while [[ "$#" -gt 0 ]]; do
		case $1 in
		-b | --base-dir)
			if [[ "$#" -gt 1 && "$2" != -* ]]; then
				BASE_DIR="$2"
				shift 2
			else
				echo -e "Error: Argument for $1 is missing.\n" >&2
				usage >&2
				return 1
			fi
			;;
		-t | --target-dir)
			if [[ "$#" -gt 1 && "$2" != -* ]]; then
				TARGET_DIR="$2"
				shift 2
			else
				echo -e "Error: Argument for $1 is missing.\n" >&2
				usage >&2
				return 1
			fi
			;;
		-s | --skip-missing)
			SKIP_MISSING=1
			shift
			;;
		-v | --verbose)
			VERBOSE=1
			shift
			;;
		-h | --help)
			usage
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
			KUSTOMIZE_ARGS+=("$1")
			if [[ "$#" -gt 1 && "$2" != -* ]]; then
				KUSTOMIZE_ARGS+=("$2")
				shift
			fi
			shift
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

	readonly ABS_BASE_DIR="$(realpath "$BASE_DIR")"

	return 0
}

kustomize_build() {
	local build_dir="$1"
	local abs_build_dir=$(realpath "$build_dir")

	# Ensure that the kustomize directory is a subdirectory of the chroot/base directory
	if [[ "$abs_build_dir" == "$ABS_BASE_DIR" || "$abs_build_dir" != "$ABS_BASE_DIR/"* ]]; then
		echo "Error: Directory '$build_dir' is not contained within the base directory ($ABS_BASE_DIR)." >&2
		return 1
	fi

	# Get the relative path to the kustomize dir from the base dir
	local rel_kustomize_dir="${abs_build_dir#$ABS_BASE_DIR/}"
	local out_dir="$TARGET_DIR/$rel_kustomize_dir"
	local manifest_file="$out_dir/manifests.yaml"
	local stderr_file="$out_dir/stderr"
	mkdir -p "$out_dir"

	if [[ "$SKIP_MISSING" -eq 1  && ! -d "$build_dir" ]]; then
		echo "[ ➖ ] $build_dir"
		return 0
	elif kustomize build "${KUSTOMIZE_ARGS[@]}" "$build_dir" -o "$manifest_file" 2>"$stderr_file"; then
		echo "[ ✅ ] $build_dir"
		return 0
	else
		echo "[ ❌ ] $build_dir"
		cat "$stderr_file" >&2
		return 1
	fi
}

kustomize_build_all() {
	echo "---------------------------  Kustomize Build ---------------------------"
	if [ $VERBOSE -gt 0 ]; then
		echo "Base Directory   : ${BASE_DIR}"
		echo "Target Directory : ${TARGET_DIR}"
		if [[ ${#KUSTOMIZE_ARGS[@]} -gt 0 ]]; then
			echo "Kustomize Args   : ${KUSTOMIZE_ARGS[@]}"
		fi
		echo "------------------------------------------------------------------------"
	fi

	local build_failed=0
	local failed_dirs=()
	for build_dir in "${BUILD_DIRS[@]}"; do
		if ! kustomize_build "$build_dir"; then
			build_failed=1
			failed_dirs+=("$build_dir")
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

main() {
	check_cli_tools kustomize

	if ! parse_args "$@"; then
		return 1
	fi

	mkdir -p "$TARGET_DIR"
	kustomize_build_all
}

main "$@"
