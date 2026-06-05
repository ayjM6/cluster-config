#!/usr/bin/env bash

set -euo pipefail

#DIR_FROM=""
#DIR_TO=""
DYFF_ARGS=("-s")
OUTPUT_FORMAT="human"
OUTPUT_MARKDOWN="false"

# ANSI color codes for our custom headers
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

usage() {
	echo "Usage: $0 <old-dir> <new-dir> [dyff_args...]"
	echo "Example: $0 target/manifests/main target/manifests/feature --omit-header"
	exit 1
}

parse_args() {
	if [[ "$#" -eq 0 ]]; then
		usage
	fi

	local args=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-o | --output)
			if [[ -n "$2" && "$2" != -* ]]; then
				OUTPUT_FORMAT="$2"
				if [[ "$OUTPUT_FORMAT" == git* ]]; then
					OUTPUT_MARKDOWN="true"
				fi
				shift 2
			else
				echo "Error: Argument for $1 is missing." >&2
				usage
			fi
			;;
		-h | --help)
			usage
			;;
		*)
			# Collect all other arguments (directories and dyff flags)
			args+=("$1")
			shift
			;;
		esac
	done

	if [[ ${#args[@]} -lt 2 ]]; then
		usage
	fi

	DIR_FROM="${args[0]}"
	DIR_TO="${args[1]}"

	# Everything else gets passed to dyff
	DYFF_ARGS+=("${args[@]:2}")
	DYFF_ARGS+=("--output" "$OUTPUT_FORMAT")
}

compare_dirs() {
	local dir_from="$1"
	local dir_to="$2"
	local reverse="${3:-false}"

	find "$dir_from" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 | while IFS= read -r -d $'\0' file_from; do
		local rel_path="${file_from#$dir_from/}"
		local file_to="$dir_to/$rel_path"

		# If doing the reverse pass, skip files we already compared in the forward pass
		if [[ "$reverse" == "true" && -f "$file_to" ]]; then
			continue
		fi

		[[ ! -f "$file_to" ]] && touch "$file_to"

		# Safely scope the dyff arguments so --swap doesn't accumulate
		local dyff_args=("${DYFF_ARGS[@]}")
		if [[ "$reverse" == "true" ]]; then
			dyff_args+=("--swap")
		fi

		local dyff_out
		set +e
		dyff_out="$(dyff between "${DYFF_ARGS[@]}" "$file_from" "$file_to")"
		dyff_rc="$?"
		set -e

		if [[ "$dyff_rc" != 0 ]]; then
			if [[ "$OUTPUT_MARKDOWN" == "true" ]]; then
				echo "<details>"
				echo "<summary><code>${rel_path}</code></summary>"
				echo ""
				echo '```diff'
				echo "$dyff_out"
				echo '```'
				echo ""
				echo "</details>"
				echo ""
			else
				echo -e "\n${COLOR_BLUE}=== $rel_path ===${COLOR_RESET}"
				echo "$dyff_out"
			fi
		fi
	done
}

main() {
	parse_args "$@"

	if [[ ! -d "$DIR_FROM" ]]; then
		echo "Error: Directory '$DIR_FROM' does not exist." >&2
		exit 1
	fi

	if [[ ! -d "$DIR_TO" ]]; then
		echo "Error: Directory '$DIR_TO' does not exist." >&2
		exit 1
	fi

	# Clean up trailing slashes for cleaner string manipulation
	DIR_FROM="${DIR_FROM%/}"
	DIR_TO="${DIR_TO%/}"

	if [[ "$OUTPUT_MARKDOWN" != "true" ]]; then
		echo "Comparing '$DIR_FROM' -> '$DIR_TO'..."
	fi

	compare_dirs "$DIR_FROM" "$DIR_TO"
	compare_dirs "$DIR_TO" "$DIR_FROM" "true"
}

# Execute main with all command-line arguments
main "$@"
