# AGENTS.md

Guidance for AI coding agents working in this repo, distilled from past
Claude Code sessions. This repo is a runnable reference implementation of a
Kustomize + OpenShift GitOps + RHACM multi-cluster fleet pattern — see
[`README.md`](README.md) for the architecture (cluster layout/classification,
overlay convention, bootstrapping) and [`docs/`](docs) for the demo
walkthrough and CI/CD. Read those before making structural changes; don't
duplicate their content here.

## Environment

- `oc`, `kustomize`, `yq`, `just`, `go` should be on `PATH`.
  `scripts/check-cli-tools.sh` verifies the runtime ones and is sourced by
  the other scripts.
- `gh` CLI is used for issues/PRs.
- Live cluster access (when available) is via `oc` contexts named after the
  clusters, e.g. `hub-prod-a`, `workload-prod-a`, `workload-qa-b` — ask
  before assuming a context exists; sessions have had these pre-configured.

## Verifying changes

- `just build [dir]` — kustomize-build changed overlays (or one `dir`).
- `just changed [ref]` — list overlays affected vs `ref` (default
  `origin/HEAD`).
- `just dyff [ref] [human|github]` — semantic diff (via `dyff`) of rendered
  manifests between `ref` and the working tree, restricted to affected
  overlays. Requires `git fetch origin` first if diffing against
  `origin/main` — it needs that ref to actually exist locally, and checks it
  out into a temporary `git worktree`.
- `just clean` — remove generated output under `target/`.
- `pre-commit run --all-files` formats YAML (`yamlfmt`, see
  `.pre-commit-config.yaml`) — run before committing YAML changes.
- This is the same machinery CI (`.github/workflows/kustomize-diff.yaml` +
  `kustomize-diff-comment.yaml`) runs on every PR into `main`, posting the
  semantic diff to the PR. It only rebuilds overlays actually affected by the
  change (`scripts/get-changed-kustomization.sh` walks dependencies via
  `scripts/kustomize-deps.sh`), so a change to a `base/` or `catalog/`
  component can affect overlays well outside the directory you edited —
  use `just changed` to check.

## Git / PR workflow

- Never commit to `main` directly — create a branch per logical change.
- The repo disallows merge commits on GitHub (squash and rebase merges only,
  branches auto-delete on merge). Once told a PR is merged, rebase local
  branches on `main` rather than merging — this comes up constantly
  (stacked PRs, force-push after a rebase).
- Before pushing a branch or opening/updating a PR, `git fetch origin` and
  rebase onto the current `origin/main` first — don't push, or ask for a PR
  to be opened, against a stale base.
- Split unrelated changes into separate PRs when asked (e.g. a cleanup PR vs.
  a feature PR) rather than bundling them.
- Use multiple commits within a branch where it aids review, and include a
  test plan in the PR description — both have been explicit, recurring asks.
- File a GitHub issue (`gh issue create`) for follow-up work that's out of
  scope for the current change, rather than leaving TODO comments — this
  repo tracks its backlog as issues.

## Kustomize / ArgoCD / RHACM gotchas learned the hard way

- **Overlay-per-cluster uniqueness**: an app may only have one overlay
  directory that matches a given cluster (`all`, its `type`, its `env`, or
  its `name` — never two). Two matches means two Argo CD `Application`s with
  the same generated name. See the overlay convention in the README before
  adding a new overlay selector.
- **ApplicationSet renames vs. deletes**: `cluster-config` (and
  `bootstrap-self`) run with `syncPolicy.preserveResourcesOnDeletion: true`
  (`bootstrap/gitops-applications/bases/cluster-config` /
  `.../bases/bootstrap-self`). This exists because a directory
  generator entry disappearing (e.g. renaming an overlay) otherwise triggers
  Argo CD to cascade-prune the old `Application`'s resources before the
  replacement `Application` can adopt them. The trade-off: actually
  decommissioning an app for good now leaves its resources orphaned
  in-cluster — they need manual cleanup, they won't be auto-pruned.
- **openshift-gitops bootstrap is a two-pass apply**: the first
  `oc apply -k bootstrap/openshift-gitops/overlays/all` has to be run twice
  — the ArgoCD CRDs aren't registered until the operator itself installs.
- **RHACM hub templating (`fromSecret`) can only read a Secret from the same
  namespace as the `Policy`.** This is why `scripts/bootstrap-git-secret.sh`
  and `scripts/bootstrap-vault-secret.sh` each write their Secret into *two*
  hub namespaces — the consumer namespace (`openshift-gitops`,
  `external-secrets`) and `open-cluster-management-policies` (the source the
  Policy templates from). Also watch for `stringData` vs `data` here —
  `fromSecret` returns an already-base64-encoded value, so sourcing it into
  `stringData` double-encodes it (see commit `ffe42a7`).
- **Secret delivery and GitOps install are two independent mechanisms** on
  purpose (RHACM `Policy` for secrets, `GitOpsCluster` + a `clusters`
  generator ApplicationSet for pushing the install) — don't collapse them,
  they're deliberately debuggable in isolation.
- **Service mesh routing**: use Gateway API `HTTPRoute` (GAMMA), not
  `VirtualService` — this repo standardized on HTTPRoute deliberately when
  the two were compared.
- **Istio Gateway auto-provisions a LoadBalancer Service** by default
  (named `<gateway>-<gatewayClassName>`). Where an OpenShift `Route` already
  fronts it, patch it to `ClusterIP` via the
  `networking.istio.io/service-type` annotation instead (see commit
  `3cffac7`) rather than leaving the redundant LB.
- **Bookinfo sidecar race**: after `openshift-service-mesh` and `bookinfo`
  both sync, bookinfo pods can start without their Envoy sidecar due to a
  startup race — `oc delete pods --all -n bookinfo` to restart them if
  `/productpage` doesn't show reviews.
- **No OCP-version-pinning overlay**: an `openshift-cluster-version` overlay
  was deliberately removed — don't reintroduce cluster-version pinning, it
  makes the demo less repeatable across OCP releases.
- **Repo auth is an SSH deploy key**, not a PAT — `git-creds` everywhere
  (hub Argo CD, spokes, RHACM Policies) is keyed off
  `cluster-config-deploy-key`/`.pub` (gitignored, generated per
  `docs/demo.md`'s prerequisites). Don't reintroduce PAT-based auth.

## Docs

- `README.md` is the architecture reference; keep it in sync with real
  overlay/`ApplicationSet` structure when either changes — it's iterated on
  heavily by hand as well as by agents, so check for a diff of manual edits
  before assuming it's stale.
- Mermaid diagrams in the README have gone through several rounds of manual
  tuning: prefer a top-down layout, one subgraph per cluster named after the
  cluster, and label edges with the verb being performed (`bootstraps`,
  `installs`, `syncs`) rather than vaguer phrasing.
- `docs/demo.md` is a runnable, step-by-step walkthrough — treat commands in
  it as things that must actually work, not illustrative snippets. Keep it
  in sync with actual bootstrap mechanics when those change.
- `docs/ci-cd.md` documents the CI mechanism described above.
