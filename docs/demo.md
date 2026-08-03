# Demo: multi-cluster bootstrap with bookinfo + OpenShift Service Mesh 3

This walks through using this repo to bootstrap a hub cluster, import two
managed clusters, and deploy bookinfo behind OpenShift Service Mesh 3 -
supporting material for the "Kustomize your multi-cluster OpenShift fleet
with OpenShift GitOps" talk.

## Prerequisites

- Three OpenShift clusters reachable via `oc`/kubeconfig: `hub-a`,
  `workload-a`, `workload-b`.
- `oc`, `kustomize`, `yq` on `PATH` (`scripts/check-cli-tools.sh` verifies
  this).
- An SSH deploy key with read access to this repo:

  ```console
  ssh-keygen -t ed25519 -f ./cluster-config-deploy-key -N ""
  gh repo deploy-key add ./cluster-config-deploy-key.pub -R ayjM6/cluster-config --title "gitops fleet (hub + spokes)"
  ```

  Keep `./cluster-config-deploy-key` (the private half) around for step 2 -
  don't commit it. The same key is used by the hub and, via the
  `bootstrap-secrets` Policy, propagated to every spoke, so one key covers
  the whole fleet.
- A Bitwarden Machine Account API token, if you want External Secrets
  Operator to actually sync (optional - see step 2).

## 1. Install OpenShift GitOps (hub-a)

Against the `hub-a` cluster:

```console
oc apply -k bootstrap/openshift-gitops/overlays/all   # operator + ArgoCD instance
```

Wait for the `openshift-gitops` operator and Argo CD instance to come up.
Don't apply `bootstrap/gitops/overlays/hub-a` yet - its ApplicationSets
pull this repo over SSH, so the `git-creds` Secret from step 2 has to
exist first or every Application will fail to sync.

## 2. Seed hub-side secrets

Still targeting `hub-a`:

```console
scripts/bootstrap-git-secret.sh
scripts/bootstrap-vault-secret.sh   # optional, only needed for External Secrets Operator
```

`bootstrap-git-secret.sh` writes the `git-creds` Secret both Argo CD (in
`openshift-gitops`) and the `bootstrap-secrets` RHACM Policy (in
`open-cluster-management-policies`) need. It prompts for the repo's SSH
URL (`git@github.com:ayjM6/cluster-config.git`) and the path to the
deploy key's private key file from the prerequisites step above.

## 3. Bootstrap the rest of the fleet from Git (hub-a)

```console
oc apply -k bootstrap/gitops/overlays/hub-a   # cluster-config + bootstrap-self ApplicationSets
```

Wait for the `bootstrap-self` ApplicationSet to sync. This installs RHACM
(`advanced-cluster-management`), the `cluster-version` and
`openshift-external-secrets` apps, and - new in this branch -
`managed-clusters` and `gitops-bootstrap-policies`.

## 4. Import workload-a and workload-b into RHACM

The `managed-clusters` app (`apps/hub/managed-clusters`) has already
created `ManagedCluster`/`KlusterletAddonConfig` objects for workload-a and
workload-b on the hub, but RHACM still needs a one-time, per-cluster import
step run against each spoke - this can't be pre-baked into Git because it
depends on a short-lived bootstrap token minted at import time.

For each of workload-a and workload-b:

1. In the RHACM console on hub-a, go to **Infrastructure > Clusters**,
   select the cluster, and follow **Import cluster** to get the import
   command (or use `clusteradm get token` / `clusteradm import` from the
   CLI).
2. Run the generated `oc apply -f ...` command(s) against that spoke
   cluster's own context.
3. Confirm on hub-a: `oc get managedcluster workload-a` (and `workload-b`)
   shows `JOINED=True` and `AVAILABLE=True`.

## 5. Verify the Policy-based spoke bootstrap

Once a spoke has joined, RHACM propagates the `bootstrap-secrets` and
`bootstrap-gitops` Policies to it (bound via the `workload-clusters`
`Placement` in `apps/hub/managed-clusters`):

```console
oc get policies -n open-cluster-management-policies
```

Both should show `Compliant` for workload-a and workload-b. This means:
the `git-creds` Secret has been delivered, OpenShift GitOps has been
installed, and the spoke's own `cluster-config` ApplicationSet exists and
is pulling from this repo.

## 6. Verify the app on each spoke

Switch context to workload-a (or workload-b) and confirm the
`openshift-service-mesh` and `bookinfo` Applications synced:

```console
oc get applications.argoproj.io -n openshift-gitops
oc get pods -n bookinfo
oc get route -n bookinfo bookinfo-gateway -o jsonpath='{.spec.host}'
```

Open the printed host in a browser and confirm `/productpage` loads with
reviews - this proves sidecar injection, mesh routing, and Gateway API
wiring all worked end to end.

## Appendix: Argo CD Agent (not built out here)

Argo CD Agent (GA in OpenShift GitOps 1.19+) is a newer way to make the
"each cluster runs its own Argo CD" pattern easier to deploy and monitor
centrally. This repo's spoke bootstrap deliberately uses the classic RHACM
Policy pattern instead (see `docs/demo-plan.md`), because Argo CD Agent
requires an OpenShift Platform Plus entitlement on every managed cluster
plus mTLS/PKI setup via `argocd-agentctl`. If you have that entitlement and
want to evolve this setup, the RHACM side moves to four CRs -
`ManagedClusterSet`, `ManagedClusterSetBinding`, `Placement`, and
`GitOpsCluster` - in place of `apps/hub/gitops-bootstrap-policies`.
