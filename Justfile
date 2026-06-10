set shell := ["bash", "-uc"]

CI := env("CI", "")
DEFAULT_DYFF_OUTPUT_ARG := if CI == "true" { "github" } else { "human" }

build-all:
	@rm -rf target/manifests
	scripts/kustomize-build.sh -t target/manifests apps/*/*/overlays/*

dyff ref="origin/main" output=DEFAULT_DYFF_OUTPUT_ARG:
	@rm -rf target/manifests target/manifests-target
	scripts/kustomize-build.sh -t target/manifests apps/*/*/overlays/*
	scripts/kustomize-build.sh -t target/manifests-target apps/*/*/overlays/* --ref {{ ref }}
	scripts/dyff-recursive.sh target/manifests-target  target/manifests -o {{ output }}

clean:
	rm -rf target/*;
