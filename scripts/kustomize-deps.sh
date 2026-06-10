#!/usr/bin/env bash

# Enforce strict error handling
set -euo pipefail

# Check for required dependencies
if ! command -v yq &> /dev/null; then
    echo "Error: 'yq' is not installed."
    exit 1
fi

if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or higher for associative arrays."
    exit 1
fi

# Ensure realpath supports --relative-to (Standard in GNU coreutils)
if ! realpath --relative-to="." . &> /dev/null; then
    echo "Error: GNU 'realpath' is required for relative path resolution."
    echo "If on macOS, you may need to install coreutils (brew install coreutils) and use 'grealpath'."
    exit 1
fi

# Associative array to track visited files and prevent infinite recursion
declare -A VISITED

# Helper: Find the exact kustomization file name in a directory
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

# Core recursive function
find_files() {
    local target="$1"

    # Resolve to absolute path to keep internal tracking consistent
    local abs_target
    abs_target=$(realpath "$target" 2>/dev/null || echo "")

    # Ignore invalid paths
    if [[ -z "$abs_target" || ! -e "$abs_target" ]]; then
        return
    fi

    # If the target is a directory, look for a kustomization file inside it
    if [[ -d "$abs_target" ]]; then
        if ! abs_target=$(get_kustomization_file "$abs_target"); then
            return # No kustomization file found; exit this branch
        fi
    fi

    # Prevent infinite loops if multiple overlays reference the same base
    if [[ -n "${VISITED[$abs_target]:-}" ]]; then
        return
    fi
    VISITED["$abs_target"]=1

    # Print the valid kustomization file relative to the current working directory
    realpath --relative-to="." "$abs_target"

    local dir_name
    dir_name=$(dirname "$abs_target")

    # Extract references using yq
    local refs
    refs=$(yq eval '
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
        .configMapGenerator[].envs[],
        .configMapGenerator[].files[],
        .secretGenerator[].envs[],
        .secretGenerator[].files[]
    ' "$abs_target" 2>/dev/null \
    | grep -E -v '^null$|^---$' \
    | grep -viE '^http|^git::' \
    | sed 's/^[^=]*=//' || true)

    # Use a newline Internal Field Separator (IFS) to safely handle spaces
    local OIFS="$IFS"
    IFS=$'\n'

    for ref in $refs; do
        local full_ref_path="$dir_name/$ref"

        if [[ -d "$full_ref_path" ]]; then
            # It's a directory (sub-kustomization). Recurse!
            find_files "$full_ref_path"
        elif [[ -f "$full_ref_path" ]]; then
            # It's a direct file reference. Print the relative path.
            realpath --relative-to="." "$full_ref_path"
        fi
    done

    # Restore original IFS
    IFS="$OIFS"
}

# Start script execution
START_DIR="${1:-.}"
find_files "$START_DIR" | sort -u
