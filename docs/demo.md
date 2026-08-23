# Demo: multi-cluster bootstrap with bookinfo + OpenShift Service Mesh 3

This walks through using this repo to bootstrap a hub cluster, import two
managed clusters, and deploy bookinfo behind OpenShift Service Mesh 3 -
supporting material for the "Kustomize your multi-cluster OpenShift fleet
with OpenShift GitOps" talk.

## Prerequisites

- Three OpenShift clusters reachable via `oc`/kubeconfig: `hub-prod-a`,
  `workload-prod-a`, `workload-qa-b`. It is recomended to provision three SNO clusters using this Demo Catalog item:
   https://catalog.demo.redhat.com/catalog/all?item=babylon-catalog-prod%2Fpublished.ocp4-cluster.prod.

  Log in to each one and rename its `oc` context to match the cluster name
  below - the rest of this doc refers to clusters by these context names
  (`oc config use-context <name>` to switch between them):

  ```console
  oc login --server=<hub-prod-a api url> --web
  oc config rename-context "$(oc config current-context)" hub-prod-a

  oc login --server=<workload-prod-a api url> --web
  oc config rename-context "$(oc config current-context)" workload-prod-a

  oc login --server=<workload-qa-b api url> --web
  oc config rename-context "$(oc config current-context)" workload-qa-b

  oc config use-context hub-prod-a   # start here for step 1
  ```

  `--web` opens a browser window to complete the OAuth login for each
  cluster, so no password ever touches the shell.
- `oc`, `kustomize`, `yq` on `PATH` (`scripts/check-cli-tools.sh` verifies
  this).
- An SSH deploy key with read access to this repo:

  ```console
  ssh-keygen -t ed25519 -f ./cluster-config-deploy-key -N ""
  gh repo deploy-key add ./cluster-config-deploy-key.pub -R ayjM6/cluster-config --title "gitops fleet (hub + spokes)"
  ```

  Keep `./cluster-config-deploy-key` (the private half) around for step 1 -
  don't commit it. The same key is used by the hub and, via the
  `bootstrap-secrets` Policy, propagated to every spoke, so one key covers
  the whole fleet.
- A Bitwarden Machine Account API token, if you want External Secrets
  Operator to actually sync (optional - see step 1).

## 1. Seed hub-side secrets

Against the `hub-prod-a` cluster, before anything else is installed:

```console
scripts/bootstrap-git-secret.sh
scripts/bootstrap-vault-secret.sh   # optional, only needed for External Secrets Operator
```

Both scripts create their own target namespaces if they don't exist yet
(`oc create namespace ... --dry-run=client -o yaml | oc apply -f -`), so
this step has no dependency on OpenShift GitOps or anything else being
installed first - it's safe to run against a bare cluster.

Each script writes its Secret into **two** namespaces in one run:

- `bootstrap-git-secret.sh` writes `git-creds` into `openshift-gitops`
  (what the hub's own Argo CD uses to pull this repo) and
  `open-cluster-management-policies` (the source Secret the
  `bootstrap-secrets` RHACM Policy reads via hub templating to deliver the
  same credential to every spoke). It prompts for the repo's SSH URL
  (`git@github.com:ayjM6/cluster-config.git`) and the path to the deploy
  key's private key file from the prerequisites step above.
- `bootstrap-vault-secret.sh` writes `bitwarden-token` into
  `external-secrets` (for the hub's own ClusterSecretStore) and
  `open-cluster-management-policies` (the source Secret the `vault-secret`
  Policy propagates to every spoke's `external-secrets` namespace).

RHACM's hub templating can only read a Secret from the same namespace as
the Policy - that's why `open-cluster-management-policies` gets a copy of
both.

## 2. Install OpenShift GitOps (hub-prod-a)

```console
oc apply -k bootstrap/openshift-gitops/overlays/all   # operator + ArgoCD instance
```

You will need to run this command twice as the ArgoCD CRDs won't be available
until the `openshift-gitops` operator installs.

Wait for the `openshift-gitops` operator and Argo CD instance to come up.

```console
oc get pods -n openshift-gitops -w
```

## 3. Bootstrap the rest of the fleet from Git (hub-prod-a)

```console
oc apply -k bootstrap/gitops-applications/overlays/hub-prod-a   # cluster-config + bootstrap-self ApplicationSets
```

Wait for the `bootstrap-self` ApplicationSet to sync. This installs RHACM
(`advanced-cluster-management`), the `cluster-version` and
`openshift-external-secrets` apps, plus three hub-only apps that drive the
rest of this demo: `managed-clusters`, `gitops-bootstrap-policies`, and
`spoke-bootstrap`.

You can check the individual applications by running:
```console
oc get applications.argoproj.io -n openshift-gitops -w
```
NOTE: this will take a while to complete due to the long time it takes to install RHACM.

## 4. Import workload-prod-a and workload-qa-b into RHACM

The `managed-clusters` app (`apps/hub/managed-clusters`) has already
created `ManagedCluster`/`KlusterletAddonConfig` objects for workload-prod-a and
workload-qa-b on the hub, but RHACM still needs a one-time, per-cluster import
step run against each spoke - this can't be pre-baked into Git because it
depends on a short-lived bootstrap token minted at import time.

For each of workload-prod-a and workload-qa-b:

1. In the RHACM console on hub-prod-a, go to **Infrastructure > Clusters**,
   select the cluster, and follow **Import cluster** to get the import
   command.
2. Run the generated `oc apply -f ...` command(s) against that spoke
   cluster's own context (e.g. run `oc config use-context workload-prod-a` 
   prior to running the import command for the `workload-prod-a` cluster)
3. Confirm on hub-prod-a: `oc get managedclusters --context hub-prod-a` shows
   `JOINED=True` and `AVAILABLE=True` for both workload-prod-a and workload-qa-b.

## 5. Verify secret delivery to each spoke

Once a spoke has joined, RHACM propagates two Policies to it - both bound
via the `workload-clusters` Placement in
`apps/hub/gitops-bootstrap-policies`:

```console
oc get policies -n open-cluster-management-policies --context hub-prod-a
```

`bootstrap-secrets` and `vault-secret` should both show `Compliant` for
workload-prod-a and workload-qa-b. This means the `git-creds` and `bitwarden-token`
Secrets have been delivered to each spoke's `openshift-gitops` /
`external-secrets` namespace - it does **not** by itself install anything
on the spoke; that's step 6.

## 6. Verify GitOps installs on each spoke

Secret delivery (step 5) and GitOps installation are two separate
mechanisms here. Installation is driven by the hub's own Argo CD: the
`spoke-bootstrap` app (`apps/hub/spoke-bootstrap`) registers each imported
spoke as an Argo CD destination via a `GitOpsCluster` CR, and its
`spoke-bootstrap` ApplicationSet pushes each spoke's `clusters/<name>`
Kustomization onto it - the same manifests applied manually in step 2/3 for
hub-prod-a, applied automatically here.

On hub-prod-a:

```console
oc get applications.argoproj.io -n openshift-gitops --context hub-prod-a | grep spoke-bootstrap
```

Look for `spoke-bootstrap-workload-prod-a` and `spoke-bootstrap-workload-qa-b` and
confirm they're `Synced`/`Healthy`. This depends on step 5 having already
delivered `git-creds` to the spoke - if it's stuck, check the Policy
compliance first.

**NOTE** A spoke's `spoke-bootstrap-<name>` app may show `Degraded` with the
spoke's `cluster-config` ApplicationSet reporting
`error generating params from git: ... connect: connection refused`. The
ArgoCD CR and the ApplicationSet are created in the same sync, so the
applicationset-controller can dial repo-server before it is listening.
Nothing is broken, but **be prepared to wait ~3 minutes**. The controller
logs the error *once* and then sits completely idle - it does not retry
until its default requeue interval (3m) fires, at which point it generates
the Applications normally. Check progress with:

```console
oc get applicationset cluster-config -n openshift-gitops --context workload-prod-a \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

## 7. Verify the app on each spoke

Switch context to workload-prod-a (or workload-qa-b) and confirm the
`openshift-service-mesh` and `bookinfo` Applications synced:

```console
oc config use-context workload-prod-a
oc get applications.argoproj.io -n openshift-gitops
oc get pods -n bookinfo
oc get route -n bookinfo bookinfo-gateway -o jsonpath='{.spec.host}'
```

**NOTE** Due to a race condition between the `openshift-service-mesh` and
`bookinfo` applications, you may need to restart all the bookinfo pods so
that they correctly pick up their envoy sidecars.
```console
oc delete pods --all -n bookinfo
```

Open the printed host in a browser and confirm `/productpage` loads with
reviews - this proves sidecar injection, mesh routing, and Gateway API
wiring all worked end to end.

## Appendix: Argo CD Agent (not built out here)

Argo CD Agent (GA in OpenShift GitOps 1.19+) is a newer way to make the
"each cluster runs its own Argo CD" pattern easier to deploy and monitor
centrally. This repo's spoke bootstrap deliberately uses the classic RHACM
patterns instead (Policies for secret delivery, `GitOpsCluster` +
ApplicationSet push for install - see `docs/demo-plan.md`), because Argo CD
Agent requires an OpenShift Platform Plus entitlement on every managed
cluster plus mTLS/PKI setup via `argocd-agentctl`. If you have that
entitlement and want to evolve this setup, the four RHACM CRs already in
use here (`ManagedClusterSet`, `ManagedClusterSetBinding`, `Placement`,
`GitOpsCluster`) carry over largely as-is - Argo CD Agent mainly changes
how the hub and spoke Argo CDs talk to each other, not this repo's
cluster-selection plumbing.
