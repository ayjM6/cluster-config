set shell := ["bash", "-uc"]

# generic defaults
CI := env("CI", "")
GIT_REF := "origin/HEAD"
DEFAULT_DYFF_OUTPUT_ARG := if CI == "true" { "github" } else { "human" }

# project specific defaults
KUST_DIRS := "apps/*/*/overlays/* bootstrap/*/overlays/*"
KUST_DIRS_QUOTED := "'apps/*/*/overlays/*' 'bootstrap/*/overlays/*'"
KUST_ARGS := ""

# by default, builds any overlays that have changed compared to origin/HEAD
# otherwise builds the given dir
build dir="":
	#!/usr/bin/env bash
	if [[ -z "{{ dir }}" ]]; then
		scripts/get-changed-kustomization.sh --ref "{{ GIT_REF }}" {{ KUST_DIRS }} | xargs -I {} bash -c 'echo "---"; kustomize build {{ KUST_ARGS }} {}'
	else
		kustomize build {{KUST_ARGS}} "{{ dir }}"
	fi


changed ref=GIT_REF:
	scripts/get-changed-kustomization.sh --ref "{{ ref }}" {{ KUST_DIRS_QUOTED }}

dyff ref=GIT_REF output=DEFAULT_DYFF_OUTPUT_ARG:
	#!/usr/bin/env bash

	set -euo pipefail

	build="$(realpath scripts/kustomize-build.sh)"

	# should we just make these /from & /to?
	target_to=target/manifests/HEAD
	target_from="target/manifests/{{ ref }}"
	rm -rf "$target_to" "$target_from"
	mkdir -p "$target_to" "$target_from"
	abs_target_to=$(realpath "$target_to")
	abs_target_from=$(realpath "$target_from")

	kust_dirs=($(just --justfile "{{ justfile() }}" changed "{{ ref }}"))

	if [[ ${#kust_dirs[@]} -eq 0 ]]; then
		echo "No overlays changed between {{ ref }} and HEAD - nothing to diff."
		exit 0
	fi

	if [[ "{{ output }}" == git* ]]; then
		echo '```'
	fi

	"$build" --skip-missing -t "$abs_target_to" -- "${kust_dirs[@]}"

	# setup the worktree dir and enforce cleanup
	worktree_dir=$(mktemp -d)
	trap git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || rm -rf "$worktree_dir" EXIT
	git worktree add --detach "$worktree_dir" "{{ ref }}" >/dev/null

	pushd "$worktree_dir" >/dev/null;
	"$build" --skip-missing -t "$abs_target_from" -- "${kust_dirs[@]}"
	popd >/dev/null;

	if [[ "{{ output }}" == git* ]]; then
		echo '```'
	fi

	scripts/dyff-recursive.sh "$target_from" "$target_to" -o "{{ output }}"

clean:
	rm -rf target/*;
