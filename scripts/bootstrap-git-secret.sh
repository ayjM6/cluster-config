#!/usr/bin/env bash
#
# Creates/updates the git-creds Secret in two places on the hub cluster:
#
#   - openshift-gitops/git-creds: the Argo CD repository credential the
#     hub's own Argo CD uses to pull this (private) repo, labeled
#     accordingly.
#   - open-cluster-management-policies/git-creds: the source Secret the
#     bootstrap-secrets RHACM Policy reads via hub templating (see
#     apps/hub/gitops-bootstrap-policies) to deliver the same credential to
#     each managed cluster. RHACM hub templates can only read a Secret from
#     the SAME namespace as the Policy, which is why it also has to live
#     here.
#
# Credential is an SSH deploy key (read-only) rather than a PAT - see
# `gh repo deploy-key add` in docs/demo.md. The repo URL must be the SSH
# form (git@host:owner/repo.git) to match the repoURL Argo CD/RHACM use
# elsewhere in this repo, since Argo CD matches repo credentials by exact
# URL.
#
# The private key is only ever read into memory (never passed as a CLI
# argument or echoed back) and applied against whatever cluster the
# current oc/KUBECONFIG context points at.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/check-cli-tools.sh"

POLICY_NAMESPACE="${GIT_SECRET_POLICY_NAMESPACE:-open-cluster-management-policies}"
ARGOCD_NAMESPACE="${GIT_SECRET_ARGOCD_NAMESPACE:-openshift-gitops}"
SECRET_NAME="${GIT_SECRET_NAME:-git-creds}"

usage() {
	echo "Usage: $(basename "$0") [--repo-url <url>] [--ssh-key-file <path>]" >&2
	echo "Creates/updates the '$SECRET_NAME' Secret in namespaces" >&2
	echo "'$ARGOCD_NAMESPACE' and '$POLICY_NAMESPACE' on whatever cluster the" >&2
	echo "current oc/KUBECONFIG context points at." >&2
	exit 1
}

REPO_URL="${GIT_REPO_URL:-}"
SSH_KEY_FILE="${GIT_SSH_KEY_FILE:-}"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo-url)
		REPO_URL="$2"
		shift 2
		;;
	--ssh-key-file)
		SSH_KEY_FILE="$2"
		shift 2
		;;
	-h | --help)
		usage
		;;
	*)
		usage
		;;
	esac
done

check_cli_tools oc yq

if [[ -z "$REPO_URL" ]]; then
	default_repo_url="$(git -C "$SCRIPT_DIR/.." remote get-url origin 2>/dev/null || true)"
	read -r -p "Git repository SSH URL [${default_repo_url:-required}]: " REPO_URL
	REPO_URL="${REPO_URL:-$default_repo_url}"
fi
if [[ -z "$REPO_URL" ]]; then
	echo "Error: a git repository URL is required." >&2
	exit 1
fi
if [[ "$REPO_URL" != git@* && "$REPO_URL" != ssh://* ]]; then
	echo "Error: repository URL must be an SSH URL (e.g. git@github.com:owner/repo.git)." >&2
	exit 1
fi

if [[ -z "$SSH_KEY_FILE" ]]; then
	read -r -p "Path to deploy key private key file: " SSH_KEY_FILE
fi
if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
	echo "Error: a readable private key file is required." >&2
	exit 1
fi
GIT_SSH_PRIVATE_KEY="$(cat "$SSH_KEY_FILE")"
if [[ -z "$GIT_SSH_PRIVATE_KEY" ]]; then
	echo "Error: '$SSH_KEY_FILE' is empty." >&2
	exit 1
fi

current_server="$(oc whoami --show-server 2>/dev/null || echo "<unknown>")"
current_user="$(oc whoami 2>/dev/null || echo "<unknown>")"
echo
echo "About to write Secret '$SECRET_NAME' in namespaces '$ARGOCD_NAMESPACE' and '$POLICY_NAMESPACE' on:"
echo "  server: $current_server"
echo "  as:     $current_user"
read -r -p "Continue? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
	echo "Aborted."
	exit 1
fi

write_secret() {
	local namespace="$1"
	local label_as_argocd_repo="$2"

	oc create namespace "$namespace" --dry-run=client -o yaml | oc apply -f - >/dev/null

	local secret_yaml
	secret_yaml="$(oc create secret generic "$SECRET_NAME" \
		--namespace "$namespace" \
		--from-literal=url="$REPO_URL" \
		--from-file=sshPrivateKey="$SSH_KEY_FILE" \
		--dry-run=client -o yaml)"

	if [[ "$label_as_argocd_repo" == "true" ]]; then
		secret_yaml="$(echo "$secret_yaml" | yq eval '.metadata.labels["argocd.argoproj.io/secret-type"] = "repository"' -)"
	fi

	echo "$secret_yaml" | oc apply -f - >/dev/null
	echo "Secret '$SECRET_NAME' written to namespace '$namespace'."
}

write_secret "$ARGOCD_NAMESPACE" true
write_secret "$POLICY_NAMESPACE" false

unset GIT_SSH_PRIVATE_KEY
