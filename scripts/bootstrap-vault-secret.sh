#!/usr/bin/env bash
#
# Creates/updates the bitwarden-token Secret in two places on the hub
# cluster:
#
#   - external-secrets/bitwarden-token: what
#     apps/core/openshift-external-secrets/stores/clustersecretstore.yaml
#     expects (namespace external-secrets, key "token") so the hub's own
#     ClusterSecretStore can authenticate.
#   - open-cluster-management-policies/bitwarden-token: the source Secret
#     the vault-secret RHACM Policy reads via hub templating (see
#     apps/hub/gitops-bootstrap-policies) to deliver the same credential to
#     each managed cluster's external-secrets namespace. RHACM hub
#     templates can only read a Secret from the SAME namespace as the
#     Policy, which is why it also has to live here (same pattern as
#     bootstrap-git-secret.sh).
#
# The token is only ever read into memory (never passed as a CLI argument
# or echoed back) and applied against whatever cluster the current
# oc/KUBECONFIG context points at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/check-cli-tools.sh"

ESO_NAMESPACE="${VAULT_SECRET_ESO_NAMESPACE:-external-secrets}"
POLICY_NAMESPACE="${VAULT_SECRET_POLICY_NAMESPACE:-open-cluster-management-policies}"
SECRET_NAME="${VAULT_SECRET_NAME:-bitwarden-token}"

usage() {
	echo "Usage: $(basename "$0")" >&2
	echo "Creates/updates the '$SECRET_NAME' Secret in namespaces" >&2
	echo "'$ESO_NAMESPACE' and '$POLICY_NAMESPACE' on whatever cluster the" >&2
	echo "current oc/KUBECONFIG context points at." >&2
	exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
fi

check_cli_tools oc

read -r -s -p "Bitwarden Machine Account API token (input hidden): " BW_TOKEN
echo >&2
if [[ -z "$BW_TOKEN" ]]; then
	echo "Error: a token is required." >&2
	exit 1
fi

current_server="$(oc whoami --show-server 2>/dev/null || echo "<unknown>")"
current_user="$(oc whoami 2>/dev/null || echo "<unknown>")"
echo
echo "About to write Secret '$SECRET_NAME' in namespaces '$ESO_NAMESPACE' and '$POLICY_NAMESPACE' on:"
echo "  server: $current_server"
echo "  as:     $current_user"
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
	echo "Aborted."
	exit 1
fi

write_secret() {
	local namespace="$1"

	oc create namespace "$namespace" --dry-run=client -o yaml | oc apply -f - >/dev/null

	oc create secret generic "$SECRET_NAME" \
		--namespace "$namespace" \
		--from-literal=token="$BW_TOKEN" \
		--dry-run=client -o yaml |
		oc apply -f - >/dev/null

	echo "Secret '$SECRET_NAME' written to namespace '$namespace'."
}

write_secret "$ESO_NAMESPACE"
write_secret "$POLICY_NAMESPACE"

unset BW_TOKEN
