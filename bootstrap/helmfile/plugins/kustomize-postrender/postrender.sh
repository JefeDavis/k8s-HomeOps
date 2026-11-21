#!/usr/bin/env sh
# Helm v4 post-renderer: applies kustomize patches to the chart output, the same
# way a Flux HelmRelease's spec.postRenderers[].kustomize does. It only knows
# about patches, not HelmReleases; the caller extracts the patches
# (templates/patches.yaml.gotmpl) and hands them over.
#
# $1: JSON array of kustomize patches (empty [] for none).
# Helm streams the rendered manifests on stdin; patched manifests go to stdout.
set -eu

patches="${1:-[]}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat >"$workdir/resources.yaml"

# No patches: pass the chart output through untouched.
if [ -z "$patches" ] || [ "$patches" = "[]" ] || [ "$patches" = "null" ]; then
  cat "$workdir/resources.yaml"
  exit 0
fi

# JSON is valid YAML; yq folds the patches into a kustomization alongside the output.
printf '%s' "$patches" \
  | yq ea '{"resources": ["resources.yaml"], "patches": .}' - \
  >"$workdir/kustomization.yaml"

kubectl kustomize "$workdir"
