#!/usr/bin/env bash
# shellcheck disable=2312
pushd integrations >/dev/null 2>&1 || exit 1

rm -rf cni/charts
envsubst <../../apps/network/cilium/app/values.yaml >cni/values.yaml
if ! kubectl get ns network >/dev/null 2>&1; then
	kubectl create ns network
fi
kustomize build --enable-helm cni | kubectl apply -f -
rm cni/values.yaml
rm -rf cni/charts

rm -rf kubelet-csr-approver/charts
envsubst <../../apps/system/kubelet-csr-approver/app/values.yaml >kubelet-csr-approver/values.yaml
if ! kubectl get ns system >/dev/null 2>&1; then
	kubectl create ns system
fi
kustomize build --enable-helm kubelet-csr-approver | kubectl apply -f -
rm kubelet-csr-approver/values.yaml
rm -rf kubelet-csr-approver/charts

rm -rf spegel/charts
envsubst <../../apps/system/spegel/app/values.yaml >spegel/values.yaml
if ! kubectl get ns system >/dev/null 2>&1; then
	kubectl create ns system
fi
kustomize build --enable-helm spegel | kubectl apply -f -
rm spegel/values.yaml
rm -rf spegel/charts
