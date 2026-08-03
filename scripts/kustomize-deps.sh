#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$(realpath "$0")")
source "$SCRIPT_DIR/check-cli-tools.sh"

declare -A VISITED
readonly OLD_IFS="$IFS"

# yq query to extract all file references
# Uses 'sub' on generator arrays to strip "key=" prefixes.
readonly YQ_FILTER_QUERY='
    .resources[],
    .bases[],
    .components[],
    .crds[],
    .transformers[],
    .generators[],
    .patches[].path,
    .patchesStrategicMerge[],
    .patchesJson6902[].path,
    .replacements[].path,
    (.configMapGenerator[].envs[] | sub("^[^=]+="; "")),
    (.configMapGenerator[].files[] | sub("^[^=]+="; "")),
    (.secretGenerator[].envs[] | sub("^[^=]+="; "")),
    (.secretGenerator[].files[] | sub("^[^=]+="; ""))
'

# Handle both kustomization.yaml and kustomization.yml files
get_kustomization_file() {
	local dir="$1"
	for f in kustomization.yaml kustomization.yml Kustomization; do
		if [[ -f "$dir/$f" ]]; then
			echo "$dir/$f"
			return 0
		fi
	done
	return 1
}

# recursively parses all the files from a given kustomization
parse_kustomization() {
	local target="$1"

	# Use absolute paths to keep internal tracking consistent
	local kust_dir=$(realpath "$target" 2>/dev/null || echo "")

	# Find the kustomziation file
	if [[ -d "$kust_dir" ]]; then
		if ! kust_file=$(get_kustomization_file "$kust_dir"); then
			return
		fi
	fi

	# Infinite loop guard
	if [[ -n "${VISITED[$kust_file]:-}" ]]; then
		return
	fi

	VISITED["$kust_file"]=1

	# Make sure we output the actual kustomization file itself
	realpath --relative-to="." "$kust_file"

	# Extract references using the global yq query
	local files=$(yq eval "$YQ_FILTER_QUERY" "$kust_file" 2>/dev/null |
		grep -E -v '^null$|^---$' |
		grep -viE '^http|^git::' || true)

	IFS=$'\n'
	for f in $files; do
		local abs_path="$kust_dir/$f"
		# recurse directories and print relative paths for files
		if [[ -d "$abs_path" ]]; then
			parse_kustomization "$abs_path"
		elif [[ -f "$abs_path" ]]; then
			realpath --relative-to="." "$abs_path"
		fi
	done
	IFS="$OLD_IFS"
}

main() {
	check_cli_tools yq

	local start_dir="${1:-.}"

	# Execute the find command and pipe to sort for clean output
	parse_kustomization "$start_dir"
}

# Start script execution
main "$@"
