set shell := ["bash", "-c"]

build-all:
	./scripts/kustomize-build.sh apps/*/*/overlays/*

kustomize-diff ref:
	./scripts/kustomize-build.sh -t target/manifests apps/*/*/overlays/*
	./scripts/kustomize-build.sh -t target/manifests-target apps/*/*/overlays/* --ref {{ref}}
	./scripts/dyff-recursive.sh -g target/manifests target/manifests-target

