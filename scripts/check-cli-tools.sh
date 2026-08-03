#!/usr/bin/env bash

set -euo pipefail

# Maps each CLI tool this project depends on to the command used to install it.
declare -A DEP_INSTALL=(
	[yq]="go install github.com/mikefarah/yq/v4@latest"
	[kustomize]="go install sigs.k8s.io/kustomize/kustomize/v5@latest"
	[dyff]="go install github.com/homeport/dyff/cmd/dyff@latest"
)

usage() {
	echo "Usage: $(basename "$0") [tool...]" >&2
	echo "Checks that the given tools (default: all of: ${!DEP_INSTALL[*]}) are on PATH." >&2
	exit 1
}

# Verifies the given tools (or all known deps, if none given) are on PATH.
# Prints an install hint for each missing tool and returns non-zero if any are missing.
check_cli_tools() {
	local tools=("$@")
	if [[ ${#tools[@]} -eq 0 ]]; then
		tools=("${!DEP_INSTALL[@]}")
	fi

	local missing=()
	for tool in "${tools[@]}"; do
		if ! command -v "$tool" &>/dev/null; then
			missing+=("$tool")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Error: missing required tool(s): ${missing[*]}" >&2
		for tool in "${missing[@]}"; do
			echo "  - $tool: install with '${DEP_INSTALL[$tool]:-see docs/ci-cd.md}'" >&2
		done
		return 1
	fi

	return 0
}

main() {
	for tool in "$@"; do
		if [[ "$tool" == "-h" || "$tool" == "--help" ]]; then
			usage
		fi
	done

	if check_cli_tools "$@"; then
		echo "All required tools are installed."
	else
		return 1
	fi
}

# Only run main when executed directly; when sourced, just expose check_cli_tools().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
