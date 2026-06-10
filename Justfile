set shell := ["bash", "-uc"]

# generic defaults
CI := env("CI", "")
DEFAULT_DYFF_OUTPUT_ARG := if CI == "true" { "github" } else { "human" }

# project specific defaults
KUSTOMIZE_DIRS := "apps/*/*/overlays/*"

build-all:
	@rm -rf target/manifests
	scripts/kustomize-build.sh -t target/manifests {{ KUSTOMIZE_DIRS }}

dyff ref="origin/main" output=DEFAULT_DYFF_OUTPUT_ARG:
	@rm -rf target/manifests target/manifests-target
	scripts/kustomize-build.sh -t target/manifests {{ KUSTOMIZE_DIRS }}
	scripts/kustomize-build.sh -t target/manifests-target {{ KUSTOMIZE_DIRS }} --ref {{ ref }}
	scripts/dyff-recursive.sh target/manifests-target  target/manifests -o {{ output }}

clean:
	rm -rf target/*;

test:
