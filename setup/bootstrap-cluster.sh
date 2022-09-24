#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)

need() {
    which "$1" &>/dev/null || die "Binary '$1' is missing but required"
}

need "kubectl"
need "helm"
need "flux"

message() {
  echo -e "\n######################################################################"
  echo "# $1"
  echo "######################################################################"
}

installFlux() {
  message "installing fluxv2"
  flux check --pre > /dev/null
  FLUX_PRE=$?
  if [ $FLUX_PRE != 0 ]; then
    echo -e "flux prereqs not met:\n"
    flux check --pre
    exit 1
  fi

  . "$REPO_ROOT"/setup/.env

  if [ -z "$GITHUB_TOKEN" ]; then
    echo "GITHUB_TOKEN is not set! Check $REPO_ROOT/setup/.env"
    exit 1
  fi
  flux bootstrap github \
    --owner=JefeDavis \
    --repository=k8s-HomeOps \
    --branch main \
    --private=true \
    --personal \
    --network-policy=false

  FLUX_INSTALLED=$?
  if [ $FLUX_INSTALLED != 0 ]; then
    echo -e "flux did not install correctly, aborting!"
    exit 1
  fi
}

installFlux
"$REPO_ROOT"/setup/bootstrap-objects.sh
"$REPO_ROOT"/setup/bootstrap-vault.sh

message "all done!"
kubectl get nodes -o=wide
