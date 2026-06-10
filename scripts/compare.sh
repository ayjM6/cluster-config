#!/usr/bin/env bash

set -euo pipefail

# todo: for now just assuming we're running at the root of the repo - enforce this later
#
WORKTREE_ROOT_DIR=target/worktrees
GIT_REF="origin/HEAD"
ORIGINAL_PWD="$PWD"

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
	WORKTREE_DIR="$WORKTREE_ROOT_DIR/$GIT_REF"

	if ! git worktree add --detach $WORKTREE_ROOT_DIR/$GIT_REF "$GIT_REF" >/dev/null 2>&1; then
		echo "Error: Failed to create git worktree for target_ref '$GIT_REF'." >&2
		return 1
	fi
}

main() {
#	local target_ref="${1:-origin/HEAD}"
#	local current_rev=$(git rev-parse HEAD)
#
#	echo "current ref: $current_rev "
#
#	local _script=$(realpath scripts/get-changed-kustomization.sh)
#
#	$_script --ref $GIT_REF apps/*/*/overlays/*
#	setup_worktree
#	pushd $WORKTREE_ROOT_DIR/$GIT_REF
#	$_script --ref $current_rev apps/*/*/overlays/*
#	popd

#	declare -A seen
#	args=('apps/*/*/overlays/*' 'bootstrap/*/overlays/*')
#
#	while IFS= read -r file; do
#		[[ -n "$file" ]] || continue
#		seen["$file"]=1
#  done < <(git diff --name-only origin/HEAD "${args[@]/%/\/kustomization.yaml}" "${args[@]/%/\/kustomization.yml}")
#	declare -p seen
#	local changed_files=$(git diff --name-only --relative "$GIT_REF" | sort -u)
#
#	local test='test
#line2'
#
#	while IFS= read -r file; do
#			[[ -n "$file" ]] || continue
#			echo $file-
#	done < <(echo "$test")

#	while IFS= read -r file; do
#		echo "Processing changed file: $file"
#	done <<< "$changed_files"

#	for d in "${args[@]}"; do
#		echo $d
#	done

	declare -A changed_files
	changed_files["src/index.js"]=1
	changed_files["config/my settings.json"]=1 # Key with a space
	changed_files["README.md"]=1

	# Loop through and print each key on a new line
	for key in "${!changed_files[@]}"; do
		echo "$key"
	done



#	while IFS= read -r file; do
#    if [[ $file == apps/*/*/overlays/*/kustomization.ya?ml ]]; then
#        MATCH_FOUND=true
#        echo "MATCHED: $(dirname $file)"
#    fi
#	done < <(git diff --name-only origin/main -- 'apps/*/*/overlays/*/kustomization.{yml,yaml}')


#	git diff --name-only --relative "$GIT_REF"

}

main "$@"
