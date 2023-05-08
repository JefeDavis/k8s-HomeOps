#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)

need() {
    which "$1" &>/dev/null || die "Binary '$1' is missing but required"
}

need "kubectl"

message() {
  echo -e "\n######################################################################"
  echo "# $1"
  echo "######################################################################"
}

kapply() {
  if output=$(envsubst < "$@"); then
    printf '%s' "$output" | kubectl apply -f -
  fi
}

installManualObjects(){
  . "$REPO_ROOT"/setup/.env

  message "installing manual secrets and objects"

  ##########
  # secrets
  ##########
read -r -d '' SYNOLOGY_CLIENT << EOM
clients:
- host: ${SYNOLOGY_URL}
  https: true
  password: ${SYNOLOGY_PASSWORD}
  port: 5001
  username: ${SYNOLOGY_USERNAME}
EOM


  kubectl -n vault create secret generic kms-vault --from-literal=account.json="$(echo $VAULT_KMS_ACCOUNT_JSON | base64 --decode)"
  kubectl -n kube-system create secret docker-registry registry-creds-secret --namespace kube-system --docker-username=$DOCKER_USERNAME --docker-password=$DOCKER_TOKEN --docker-email=$EMAIL
  kubectl -n storage-controllers create secret generic synology-csi-secret --from-literal=client-info.yaml="${SYNOLOGY_CLIENT}"

}

export KUBECONFIG="$REPO_ROOT/setup/kubeconfig"
installManualObjects

message "all done!"
