# CI/CD: Kustomize Diff Check

On every PR into `main`, [.github/workflows/kustomize-diff.yaml](../.github/workflows/kustomize-diff.yaml)
renders the kustomize output for the PR branch and for `main`, diffs them with
[`dyff`](https://github.com/homeport/dyff), and posts the result to the PR's
GitHub Actions job summary. This gives reviewers a semantic diff of the actual
rendered Kubernetes manifests, not just the kustomize source files.

Only overlays affected by the PR are rebuilt, not the whole repo.

## How it works

1. **Find changed overlays** — `scripts/get-changed-kustomization.sh` compares
   the PR against the base ref and figures out which overlays under
   `apps/*/*/overlays/*` and `bootstrap/*/overlays/*` are affected. An overlay
   is flagged if its own `kustomization.yaml` changed, or if any file it
   depends on changed. Dependencies are resolved recursively by
   `scripts/kustomize-deps.sh`, which uses `yq` to walk `resources`, `bases`,
   `components`, `patches`, `configMapGenerator`/`secretGenerator` files, etc.
2. **Build "new" manifests** — `scripts/kustomize-build.sh` builds the changed
   overlays from the current checkout into `target/manifests/HEAD`.
3. **Build "old" manifests** — a temporary `git worktree` is checked out at
   the base ref, and the same overlays are built from there into
   `target/manifests/<base-ref>`.
4. **Diff** — `scripts/dyff-recursive.sh` runs `dyff between` on each matching
   file pair across the two output trees (handling files that only exist on
   one side too), and formats the result as collapsible Markdown suitable for
   `$GITHUB_STEP_SUMMARY`.

All of the above is orchestrated by the `dyff` recipe in the [Justfile](../Justfile).

## Running it locally

Requires `just`, `go`, and the following Go-installed tools on `PATH`:

```bash
go install github.com/homeport/dyff/cmd/dyff@v1.12.0
go install sigs.k8s.io/kustomize/kustomize/v5@latest
go install github.com/mikefarah/yq/v4@latest
```

> **`yq` is required**, not optional — `kustomize-deps.sh` silently swallows
> `yq` errors. If `yq` is missing, dependency resolution quietly returns
> nothing for every overlay, so changes to a shared `base/` or `component/`
> won't be detected as affecting any overlay. This can surface as a confusing
> `Directory '.' is not contained within the base directory` error from
> `kustomize-build.sh`, since an empty changed-overlays list falls through to
> a bad default of building `.` itself.

Then, from the repo root with an up-to-date `origin`:

```bash
git fetch origin
just dyff origin/main human
```

- `origin/main` is the ref to diff against.
- `human` produces colorized terminal output. Use `github` to preview the
  exact Markdown that would be posted to the PR summary.

Clean up generated output with:

```bash
just clean
```
