#!/usr/bin/env bash
rm -rf app/charts
echo "# This manifest was generated by automation. DO NOT EDIT." > ./cilium.yaml
kustomize build \
  --enable-helm \
  --load-restrictor=LoadRestrictionsNone \
  . \
  >> ./cilium.yaml
rm -rf app/charts
