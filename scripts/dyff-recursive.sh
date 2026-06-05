#!/usr/bin/env bash

set -euo pipefail

#DIR_FROM=""
#DIR_TO=""
DYFF_ARGS=()

# ANSI color codes for our custom headers
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

usage() {
    echo "Usage: $0 <old-dir> <new-dir> [dyff_args...]"
    echo "Example: $0 target/manifests/main target/manifests/feature --omit-header"
    exit 1
}

parse_args() {
    if [[ "$#" -lt 2 ]]; then
        usage
    fi

    DIR_FROM="$1"
    DIR_TO="$2"
    shift 2

    DYFF_ARGS=("$@")
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

        if [[ "$reverse" == "true" ]]; then
        	DYFF_ARGS+=("--swap")
				fi

        echo -e "\n${COLOR_BLUE}=== $rel_path ===${COLOR_RESET}"

        [[ ! -f "$file_to" ]] && touch "$file_to"

        dyff between "${DYFF_ARGS[@]}" "$file_from" "$file_to" || true
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

    echo "Comparing '$DIR_FROM' -> '$DIR_TO'..."

    # 1. Forward pass (Compares existing files AND detects deletions)
    compare_dirs "$DIR_FROM" "$DIR_TO"


		echo "############################### UNO REVERSE"
    # 2. Reverse pass (Detects additions, skips files already compared)
    compare_dirs "$DIR_TO" "$DIR_FROM" "true"

    echo -e "\nComparison complete."
}

# Execute main with all command-line arguments
main "$@"
