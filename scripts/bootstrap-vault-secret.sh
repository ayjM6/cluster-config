#!/usr/bin/env bash
#
# Creates/updates the bitwarden-token Secret that
# apps/core/openshift-external-secrets/stores/clustersecretstore.yaml
# expects (namespace external-secrets, key "token"), but that nothing in
# this repo creates - the ClusterSecretStore can't authenticate without it.
#
# The token is only ever read into memory (never passed as a CLI argument
# or echoed back) and applied against whatever cluster the current
# oc/KUBECONFIG context points at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/check-cli-tools.sh"

NAMESPACE="${VAULT_SECRET_NAMESPACE:-external-secrets}"
SECRET_NAME="${VAULT_SECRET_NAME:-bitwarden-token}"

usage() {
	echo "Usage: $(basename "$0")" >&2
	echo "Creates/updates the '$SECRET_NAME' Secret in namespace '$NAMESPACE'" >&2
	echo "on whatever cluster the current oc/KUBECONFIG context points at." >&2
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
echo "About to write Secret '$SECRET_NAME' in namespace '$NAMESPACE' on:"
echo "  server: $current_server"
echo "  as:     $current_user"
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
	echo "Aborted."
	exit 1
fi

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc create secret generic "$SECRET_NAME" \
	--namespace "$NAMESPACE" \
	--from-literal=token="$BW_TOKEN" \
	--dry-run=client -o yaml |
	oc apply -f - >/dev/null

unset BW_TOKEN

echo "Secret '$SECRET_NAME' written to namespace '$NAMESPACE'."
