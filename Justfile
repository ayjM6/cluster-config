set shell := ["bash", "-uc"]

# generic defaults
CI := env("CI", "")
GIT_REF := "origin/HEAD"
DEFAULT_DYFF_OUTPUT_ARG := if CI == "true" { "github" } else { "human" }

# project specific defaults
KUST_DIRS := "apps/*/*/overlays/* bootstrap/*/overlays/*"
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

dyff ref=GIT_REF output=DEFAULT_DYFF_OUTPUT_ARG:
	#!/usr/bin/env bash

	# should we just make these /from & /to?
	target_to=target/manifests/HEAD
	target_from="target/manifests/{{ ref }}"

	rm -rf "$target_from" "$target_to"

	kust_dirs=$(scripts/get-changed-kustomization.sh --ref {{ ref }} {{ KUST_DIRS }})
	scripts/kustomize-build.sh -t "$target_to" <<< "$kust_dirs"
	scripts/kustomize-build.sh -t "$target_from" --ref {{ ref }} <<< "$kust_dirs"
	scripts/dyff-recursive.sh "$target_from" "$target_to" -o "{{ output }}"

clean:
	rm -rf target/*;

test:
