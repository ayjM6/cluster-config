#!/bin/bash

# ==========================================
# Global Configuration State (Defaults)
# ==========================================
OUTPUT_DIR="target"
GIT_REF="HEAD"
BUILD_DIRS=()
KUSTOMIZE_ARGS=()

# ==========================================
# Argument Parsing Function
# ==========================================
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -d|--directory)
                if [[ -n "$2" && "$2" != -* ]]; then
                    OUTPUT_DIR="$2"
                    shift 2
                else
                    echo "Error: Argument for $1 is missing." >&2
                    return 1
                fi
                ;;
            --ref)
                if [[ -n "$2" && "$2" != -* ]]; then
                    GIT_REF="$2"
                    shift 2
                else
                    echo "Error: Argument for $1 is missing." >&2
                    return 1
                fi
                ;;
            -k|--kustomize-arg)
                if [[ -n "$2" ]]; then
                    KUSTOMIZE_ARGS+=("$2")
                    shift 2
                else
                    echo "Error: Argument for $1 is missing." >&2
                    return 1
                fi
                ;;
            -h|--help)
                echo "Usage: $0 [-d <out-dir>] [--ref <ref>] [-k <arg>] [directories...]"
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

    # Default to current directory (.) if no directories were specified
    if [[ ${#BUILD_DIRS[@]} -eq 0 ]]; then
        echo "No directories specified. Defaulting to (.)."
        BUILD_DIRS=(".")
    fi

    return 0
}

# ==========================================
# Single Overlay Build Function
# ==========================================
kustomize_build() {
    local dir="$1"
    local abs_root="$2"

    # 1. Resolve absolute path of the target directory
    local abs_dir
    if ! abs_dir=$(realpath "$dir"); then
        echo "Error: Target directory '$dir' does not exist." >&2
        return 1
    fi

    # 2. Strict containment check
    if [[ "$abs_dir" != "$abs_root" && "$abs_dir" != "$abs_root/"* ]]; then
        echo "Error: Directory '$dir' is not contained within the current working directory ($PWD)." >&2
        return 1
    fi

    # 3. Determine relative path to construct output folder
    local relative_path
    if [[ "$abs_dir" == "$abs_root" ]]; then
        relative_path="root"
    else
        relative_path="${abs_dir#$abs_root/}"
    fi

    # 4. Construct output paths for this specific overlay
    local overlay_out_dir="$OUTPUT_DIR/$relative_path"
    mkdir -p "$overlay_out_dir"

    local manifest_file="$overlay_out_dir/manifests.yaml"
    local stdout_file="$overlay_out_dir/stdout"
    local stderr_file="$overlay_out_dir/stderr"

    echo "Building: $dir"

    # 5. Execute Kustomize and route outputs to the respective files
    if kustomize build "${KUSTOMIZE_ARGS[@]}" "$dir" > "$stdout_file" 2> "$stderr_file"; then
        # Copy the raw stdout to manifests.yaml for your explicit file requirement
        cp "$stdout_file" "$manifest_file"
        echo "  -> Success: Generated $manifest_file"
        return 0
    else
        echo "  -> Error: Kustomize build failed for $dir. Check $stderr_file for details." >&2
        return 1
    fi
}

# ==========================================
# Master Build Controller Function
# ==========================================
kustomize_build_all() {
    echo "--- Starting Kustomize Build ---"
    echo "Git Ref          : $GIT_REF"
    echo "Root Directory   : $PWD"
    echo "Output Directory : $OUTPUT_DIR"
    echo "Kustomize Args   : ${KUSTOMIZE_ARGS[*]}"
    echo "Target Dirs      : ${BUILD_DIRS[*]}"
    echo "--------------------------------"

    # Resolve absolute path of the root directory once to pass down to workers
    local abs_root
    if ! abs_root=$(realpath "$PWD"); then
        echo "Error: Could not resolve absolute path for current working directory." >&2
        exit 1
    fi

    for dir in "${BUILD_DIRS[@]}"; do
        if ! kustomize_build "$dir" "$abs_root"; then
            # Fail fast on the first error
            exit 1
        fi
    done

    echo "--------------------------------"
    echo "Build process completed successfully."
}

# ==========================================
# Main Execution Block
# ==========================================
main() {
    if ! parse_args "$@"; then
        exit 1
    fi

    if ! command -v kustomize &> /dev/null; then
        echo "Error: kustomize is not installed or not in your PATH." >&2
        exit 1
    fi

    if ! command -v realpath &> /dev/null; then
        echo "Error: realpath command is required but not found in your PATH." >&2
        exit 1
    fi

    kustomize_build_all
}

main "$@"
