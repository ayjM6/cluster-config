<details>
<summary><code>apps/core/cluster-version/overlays/hub-a/manifests.yaml</code></summary>

```diff

@@ (root level) @@
! - one document removed:
- apiVersion: config.openshift.io/v1
- kind: ClusterVersion
- metadata:
-   name: version
-   annotations:
-     argocd.argoproj.io/sync-options: ServerSideApply=true
- spec:
-   channel: stable-4.19
-   desiredUpdate:
-     version: "4.19.16"
```

</details>

<details>
<summary><code>apps/core/openshift-external-secrets/overlays/all/manifests.yaml</code></summary>

```diff

@@ (root level) @@
! + one document added:
+ apiVersion: v1
+ kind: Namespace
+ metadata:
+   name: external-secrets

@@ (root level) @@
! + one document added:
+ apiVersion: v1
+ kind: Namespace
+ metadata:
+   name: external-secrets-operator
+   annotations:
+     argocd.argoproj.io/sync-wave: "-10"

@@ (root level) @@
! + one document added:
+ apiVersion: cert-manager.io/v1
+ kind: Certificate
+ metadata:
+   name: bitwarden-tls-certs
+   namespace: external-secrets
+ spec:
+   dnsNames:
+   - bitwarden-sdk-server.external-secrets.svc.cluster.local
+   - external-secrets-bitwarden-sdk-server.external-secrets.svc.cluster.local
+   - localhost
+   duration: 8760h0m0s
+   ipAddresses:
+   - "127.0.0.1"
+   - "::1"
+   issuerRef:
+     name: self-signed
+     group: cert-manager.io
+     kind: Issuer
+   privateKey:
+     algorithm: RSA
+     encoding: PKCS8
+     size: 2048
+   renewBefore: 30m0s
+   secretName: bitwarden-tls-certs

@@ (root level) @@
! + one document added:
+ apiVersion: cert-manager.io/v1
+ kind: Issuer
+ metadata:
+   name: self-signed
+   namespace: external-secrets
+ spec:
+   selfSigned: {}

@@ (root level) @@
! + one document added:
+ apiVersion: external-secrets.io/v1beta1
+ kind: ClusterSecretStore
+ metadata:
+   name: default
+ spec:
+   provider:
+     bitwardensecretsmanager:
+       auth:
+         secretRef:
+           credentials:
+             name: bitwarden-token
+             key: token
+             namespace: external-secrets
+       apiURL: "https://api.bitwarden.com"
+       bitwardenServerSDKURL: "https://bitwarden-sdk-server.external-secrets.svc.cluster.local:9998"
+       identityURL: "https://identity.bitwarden.com"
+       organizationID: 9c351068-4b85-4ec4-90d6-b37300cb91a7
+       projectID: 682ed35a-9781-4a47-a8b7-b37c005d51bd
+       caProvider:
+         name: bitwarden-tls-certs
+         type: Secret
+         key: ca.crt
+         namespace: external-secrets

@@ (root level) @@
! + one document added:
+ apiVersion: operator.openshift.io/v1alpha1
+ kind: ExternalSecrets
+ metadata:
+   name: cluster
+   namespace: external-secrets
+ spec:
+   externalSecretsConfig:
+     bitwardenSecretManagerProvider:
+       enabled: "true"
+       secretRef:
+         name: bitwarden-tls-certs

@@ (root level) @@
! + one document added:
+ apiVersion: operators.coreos.com/v1
+ kind: OperatorGroup
+ metadata:
+   name: openshift-gitops-operator
+   namespace: external-secrets-operator
+   annotations:
+     argocd.argoproj.io/sync-wave: "-10"
+ spec:
+   upgradeStrategy: Default

@@ (root level) @@
! + one document added:
+ apiVersion: operators.coreos.com/v1alpha1
+ kind: Subscription
+ metadata:
+   name: openshift-external-secrets-operator
+   namespace: external-secrets-operator
+   annotations:
+     argocd.argoproj.io/sync-wave: "-10"
+ spec:
+   name: openshift-external-secrets-operator
+   source: redhat-operators
+   channel: tech-preview-v0.1
+   installPlanApproval: Automatic
+   sourceNamespace: openshift-marketplace
```

</details>

<details>
<summary><code>apps/hub/advanced-cluster-management/overlays/hub-a/manifests.yaml</code></summary>

```diff

@@ metadata.annotations.argocd.argoproj.io/sync-wave @@
# v1/Namespace/open-cluster-management
! ± value change in multiline text (one insert, one deletion)
- -10
+ -5
```

</details>

