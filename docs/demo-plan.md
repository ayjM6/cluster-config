# Demo repo plan: bootstrap hub-a → import workload-a/workload-b → bookinfo + OpenShift Service Mesh 3

## Context

You and your colleagues presented a conference talk describing a Kustomize/OpenShift-GitOps/RHACM pattern built for a customer. You want to turn the repo that pattern is based on into a runnable demo that supports the talk: bootstrap a hub cluster, import two managed clusters, and deploy bookinfo behind OpenShift Service Mesh 3.

**Repo**: work happens in `~/code/cluster-config` (its git remote `ayjM6/cluster-config` matches the exact URL shown in slide 18 of the deck — this is the real repo, not the empty `kustomizing-gitops` directory). Branch from `install-rhacm` (already has working ACM 2.15 + hub-a bootstrap) into a new branch, e.g. `demo/multi-cluster-bookinfo`.

**Decisions confirmed with you:**
- Target infra: 3 pre-existing OpenShift clusters (hub-a + workload-a + workload-b), reachable via kubeconfig. No cluster-provisioning automation needed.
- workload-a/workload-b are **imported** as existing clusters into RHACM (not provisioned via Hive).
- Spoke GitOps bootstrap: **primary path uses the classic RHACM Policy pattern** (slides 25–28 — Policies deliver git-creds, then OpenShift GitOps bootstraps itself and pulls the rest). This keeps each spoke's Argo CD fully independent and is what the talk actually describes as the production pattern. Note RHACM itself (installed on hub-a either way, for cluster import) requires its own entitlement — either a standalone RHACM subscription or via OpenShift Platform Plus (OPP) — so that cost is already "baked in" regardless of which spoke-bootstrap path you pick. **Argo CD Agent (slide 24's forward-looking mention) is documented as an optional appendix**, not the core path, since it specifically requires the **OpenShift Platform Plus** bundle (not just standalone RHACM) on every managed cluster, not just the hub, plus mTLS/PKI setup via `argocd-agentctl`.

**Current state** (verified by reading the repo): hub-a bootstrap already works end-to-end (`bootstrap/openshift-gitops/overlays/all` → `bootstrap/gitops/overlays/hub-a` → ACM operator+instance). Everything else needed for the demo — spoke import, Policy-based bootstrap, and the Service Mesh operator — does not exist yet anywhere in the repo (verified via repo-wide grep: zero `ManagedCluster`, `KlusterletAddonConfig`, `Policy`, `Istio`/`servicemesh` resources).

---

## 1. Hub cluster bootstrap (hub-a) — verify, don't rebuild

This already works; just validate and document it as the first demo step:
```
oc apply -k bootstrap/openshift-gitops/overlays/all      # operator + ArgoCD instance
oc apply -k bootstrap/gitops/overlays/hub-a               # cluster-config + bootstrap-self ApplicationSets
```
Confirm on a real hub-a cluster that both ApplicationSets sync clean (`cluster-version`, `advanced-cluster-management`, `openshift-external-secrets`, `openshift-config`, plus the two `bootstrap-self-*` apps). No code changes required here beyond the cleanup items in §5.

## 2. Import workload-a and workload-b into RHACM

New app: **`apps/hub/managed-clusters/`** (new directory, follows the existing `apps/hub/advanced-cluster-management` base/instance/overlay shape), deployed to hub-a via the existing `cluster-config` ApplicationSet (`apps/*/*/overlays/hub-a` glob already matches).

Contents to author:
- A `ManagedClusterSet` (e.g. `workload`) + `ManagedClusterSetBinding` in the `open-cluster-management` policy namespace, and a `Placement` selecting `ManagedCluster`s labeled `type: workload` — reuses this repo's own `type`/`env`/`name` label taxonomy from the `vars` ConfigMap pattern (nice continuity with the talk's "categorise clusters" slide).
- Per spoke, a `ManagedCluster` + `KlusterletAddonConfig` pair (labels `type: workload`, `name: workload-a` / `workload-b`) — this is what RHACM uses to accept the import. Note: the actual **one-time import bootstrap** (the `curl`-piped `oc apply` command RHACM's console/API generates, containing a short-lived import token) is inherently imperative and per-cluster — it can't be pre-baked into Git. Document it as a manual runbook step (`clusteradm get token` / ACM console "Import cluster" flow) rather than trying to GitOps it.

## 3. RHACM Policy-based spoke bootstrap (the talk's core mechanism)

New app: **`apps/hub/gitops-bootstrap-policies/`**, also deployed to hub-a, bound to the `Placement` from §2.

Two `Policy` objects (with `PlacementBinding`s to the workload `Placement`):
1. **`bootstrap-secrets`** — delivers the `git-creds` Secret to each spoke using RHACM's hub templating (`{{hub fromSecret ...hub}}`) to copy a value that already exists as a Secret on the hub, so the credential is never stored in Git. The hub-side source Secret is created by the new `scripts/bootstrap-git-secret.sh` (see §4) — the Policy only ever references it by name/namespace, never its value.
2. **`bootstrap-gitops`** — installs OpenShift GitOps and applies the `gitops` ApplicationSet layer on the spoke, i.e. enforces the same two manifests already used for hub-a: `bootstrap/openshift-gitops/overlays/all` and a new `bootstrap/gitops/overlays/workload-a` / `workload-b`.

Use the **`PolicyGenerator`** plugin (`open-cluster-management-io/policy-generator-plugin`) to wrap these existing Kustomize directories into Policies automatically, rather than hand-duplicating the manifests as `ConfigurationPolicy` YAML — this reuses real Kustomize output and matches the repo's own "avoid layers of abstraction" principle. Favor two explicit Policies (one per spoke, or one Policy fanned out via two `Placement`s each selecting a single named cluster) over hub-template magic for the `name` var — keeps it easy to follow live, consistent with "three similar lines beats a premature abstraction."

New bootstrap overlays needed (mirror the existing `hub-a` pattern exactly):
- `bootstrap/gitops/overlays/workload-a/kustomization.yaml` — `resources: [../../bases/workload]`, `vars` ConfigMap `name=workload-a`.
- `bootstrap/gitops/overlays/workload-b/kustomization.yaml` — same, `name=workload-b`.

No `GitOpsCluster` CR is needed for this path — that CR is specifically for the centralized-targeting pattern (used by ApplicationSet's `cluster-decision-resource` generator or by Argo CD Agent), and isn't needed since each spoke bootstraps and manages itself independently.

## 4. Secret bootstrap scripts (git creds + Bitwarden vault token)

Per your request, add interactive scripts (alongside the existing `scripts/*.sh`, following `check-cli-tools.sh`'s style) that seed the real, hub-side "source of truth" Secrets imperatively — these must never be committed to Git, only their *names* are referenced by the Policy/ClusterSecretStore manifests in Git:

- **`scripts/bootstrap-git-secret.sh`** — prompts for a GitHub auth token (`read -rs`, no echo, never passed as a CLI arg so it doesn't leak into shell history or `ps`), creates/updates the `git-creds` Secret on the hub cluster (namespace `openshift-gitops`) via `oc create secret generic ... --dry-run=client -o yaml | oc apply -f -` so it's idempotent/safe to re-run. This is both the Secret Argo CD itself uses for repo access (if the repo is private) and the source Secret the `bootstrap-secrets` Policy from §3 hub-templates out to each spoke.
- **`scripts/bootstrap-vault-secret.sh`** — prompts for a Bitwarden Machine Account API token, creates/updates the `bitwarden-token` Secret (namespace `external-secrets`, key `token`) that `apps/core/openshift-external-secrets/stores/clustersecretstore.yaml` already expects but that nothing in the repo currently creates. This removes the "External Secrets Operator can't authenticate" gap flagged in §6, so ESO/Bitwarden can stay **in scope** for the demo instead of being excluded.

Both scripts should: target whatever cluster the current `oc`/`KUBECONFIG` context points at, print that context and ask for an explicit confirm before writing anything (these create real credentials on a cluster), and never print the secret value back out. Document them as required pre-steps in the runbook (§7) — run once per hub-a (and, if you want ESO on the spokes too, once per spoke).

## 5. Bookinfo + OpenShift Service Mesh 3

**New app: `apps/workload/openshift-service-mesh/`** — reuse `redhat-cop/gitops-catalog`'s existing `redhat-openshift-servicemesh-3` directory (confirmed present) the exact same way this repo already pulls the OpenShift GitOps and ACM operators — pinned remote bases, `catalog/components/syncwaves/operators` component for early sync-wave ordering:
- `operator/kustomization.yaml` → remote base `redhat-openshift-servicemesh-3/operator/overlays/stable-3.0` (Sail Operator subscription), + syncwaves component (wave `-10`, same pattern as ACM/GitOps operators).
- `instance/kustomization.yaml` → remote base `redhat-openshift-servicemesh-3/instance/overlays/v1.24-latest` (`Istio` + `IstioCNI` CRs — version `v1.24` matches the `release-1.24` bookinfo samples already referenced in this repo, so no version mismatch to fix).
- `overlays/workload/kustomization.yaml` — combines operator + instance, targeted at `type=workload` so it applies to **both** workload-a and workload-b without duplication.
- Optional stretch: also pull in `redhat-openshift-servicemesh-3/observability` (Kiali + console plugin) — gives a live traffic-graph visual during the demo. Verify during implementation whether the Kiali Operator needs its own separate Subscription (it's typically a distinct operator from Sail).

Note: the existing (currently unused) `istio-discovery: enabled` label on the bookinfo namespace already matches the `meshConfig.discoverySelectors` in the gitops-catalog `Istio` CR — confirms the bookinfo app was scaffolded expecting exactly this mesh config.

**Fix existing `apps/workload/bookinfo/`:**
- `base/namespace.yaml`: fix the `bookinfox` → `bookinfo` typo (currently mismatches the Kustomization's `namespace: bookinfo`, which only stamps namespaced resources, not the Namespace object's own name).
- `base/route.yaml`: verify the `Service/istio-ingressgateway` target against what the Gateway API resources from the `openshift-service-mesh/istio` bookinfo samples actually provision under OSSM3/Sail — this needs empirical verification once the mesh is installed on a real cluster (likely needs updating to whatever Service name the `Gateway` resource auto-provisions).
- Rename `overlays/workload-prod` → `overlays/workload` (matches `openshift-service-mesh`'s and `openshift-pipelines`'s overlay naming, and correctly targets both workload-a/workload-b via the `type=workload` glob level instead of a nonexistent per-cluster name).

Sync-wave ordering already works out of the box: the mesh operator gets wave `-10` (via the syncwaves component) so it installs before bookinfo (default wave `0`) — no extra `RollingSync`/progressive-sync config needed for this pair, though it's worth calling out live as a callback to slide 41.

## 6. Demo-hygiene cleanup (do before rehearsing, not architecturally required)

- `apps/core/openshift-external-secrets/overlays/all` currently matches **every** cluster (including workload-a/b) and depends on the `bitwarden-token` Secret + hardcoded org/project IDs that look like real credentials. With `scripts/bootstrap-vault-secret.sh` (§4) run once per cluster, the Secret will actually exist, so this no longer needs to be excluded from the demo — just make sure the script has been run on every cluster before the ApplicationSet syncs there, or it'll show degraded until you do. Flag to your co-presenters whether the hardcoded org/project IDs are meant to stay private before this repo is shared publicly.
- `apps/core/openshift-config/overlays/all` is scratch/test content (`test.txt`/`test2.txt` containing `asfdasd`) — either delete or replace with something real before showing it live.
- `apps/workload/openshift-pipelines` is an empty stub (`resources: []`) — either wire it up minimally (same remote-base pattern as the other operators) or drop it from the demo's app set so it doesn't show as a confusing empty Application.
- `scripts/compare.sh` is dead scratch code, not wired into anything — fine to delete.
- `.github/workflows/kustomize-diff.yaml` never installs `kustomize`/`yq`, only `dyff` — worth fixing if you plan to demo the CI diff-comment flow live, otherwise skip.

## 7. Documentation

Add a `README.md` / `docs/demo.md` runbook capturing the exact commands in order (hub bootstrap → `scripts/bootstrap-git-secret.sh` / `scripts/bootstrap-vault-secret.sh` → RHACM import token step → policy bootstrap verification → mesh/bookinfo verification → Route URL), mirroring the talk's "Voyage Ahead" flow so conference attendees can follow along without re-deriving it. Include a short **appendix** describing the optional Argo CD Agent path (OpenShift GitOps 1.19+, OPP entitlement, `argocd-agentctl`, `ManagedClusterSet`/`ManagedClusterSetBinding`/`Placement`/`GitOpsCluster`) as "how you'd evolve this once you have Platform Plus," without building it out.

## Verification

- Render every new/changed overlay locally before touching real clusters: `just build apps/hub/managed-clusters/overlays/hub-a`, `just build apps/hub/gitops-bootstrap-policies/overlays/hub-a`, `just build apps/workload/openshift-service-mesh/overlays/workload`, `just build apps/workload/bookinfo/overlays/workload`, `just build bootstrap/gitops/overlays/workload-a`, `just build bootstrap/gitops/overlays/workload-b`.
- Use `just dyff origin/install-rhacm human` (or against `main`) to sanity-check the full diff before applying anywhere.
- End-to-end on real clusters: apply hub-a bootstrap → run `scripts/bootstrap-git-secret.sh` and `scripts/bootstrap-vault-secret.sh` against hub-a → confirm ACM console shows hub-a healthy → import workload-a/workload-b (manual token step) → confirm the two `Policy` objects show `Compliant` for both spokes → confirm each spoke's own `openshift-gitops` comes up and its `cluster-config` ApplicationSet syncs `openshift-service-mesh` then `bookinfo` → hit the bookinfo Route and confirm the product page loads with reviews (proves the mesh sidecar injection + gateway routing works).
