# ADR 0003: Bootstrap with Helmfile and mise

## Context

A fresh Talos cluster is a chicken-and-egg problem: there is **no CNI**, so pods cannot get IPs
or resolve DNS; there are **no Flux CRDs or controllers**, so nothing is reconciling git yet. Flux
cannot install the very things it needs in order to run. Something outside the GitOps loop has to
lay down the first layer, CNI, DNS, an image cache, and Flux itself, and then hand off.

The hard requirement is that this first layer be installed with the **exact same chart versions,
values, and patches** that Flux will use forever after. If bootstrap and steady-state diverge, the
first Flux reconcile will fight the bootstrap install (re-render, restart pods, or drift), which is
precisely the failure a GitOps cluster is supposed to avoid.

## Decision

Bootstrap with **Helmfile**, orchestrated by **mise** tasks, reading its chart refs/values/patches
**directly from the same `kubernetes/apps/**/{ocirepo,helmrelease}.yaml` manifests** that Flux
reconciles. Tool versions are pinned by mise so every operator bootstraps identically.

### The handoff sequence (`mise run bootstrap:cluster`)

1. **Talos config → nodes.** Apply machine config to all three nodes (`talosctl apply-config`).
2. **Kubernetes bootstrap.** `talosctl bootstrap` on one controller (idempotent; retries to
   `AlreadyExists`) brings up etcd + the control plane.
3. **Fetch kubeconfig**, then **wait** for the API server (`/readyz`) and for all nodes `Ready`.
4. **CRDs first.** `helmfile -f helmfile/crds.yaml template` is filtered to just
   `kind: CustomResourceDefinition` and applied server-side. This installs the CRDs for
   **envoy-gateway, grafana-operator, kube-prometheus-stack-crds, and kyverno** up front, which
   is the premise [ADR 0004](0004-prune-crd-dependencies.md) relies on to drop CRD-ordering
   `dependsOn` across the repo.
5. **Core apps.** `helmfile -f helmfile/apps.yaml sync` installs, in `needs` order:
   `cilium → coredns → spegel → flux-operator → flux-instance`. Cilium brings up the datapath
   (its BGP/LB-IPAM config is applied via pre/post hooks); coredns restores DNS; spegel provides
   the in-cluster registry mirror; flux-operator + flux-instance stand Flux up.
6. **Flux takes over.** The `FluxInstance` points at the `k8s-homeops` GitRepository (`main`,
   path `kubernetes/apps`) and from here Flux reconciles everything else continuously.

### DRY: one source of truth for bootstrap and GitOps

Helmfile does **not** carry its own copy of chart versions or values. Templated `.gotmpl` helpers
read them out of the app manifests at render time:

- `release.yaml.gotmpl` → `chart` + `version` from the app's `ocirepo.yaml` (`spec.url`, `spec.ref.tag`).
- `values.yaml.gotmpl` → `spec.values` from the app's `helmrelease.yaml`.
- `patches.yaml.gotmpl` → `spec.postRenderers[].kustomize.patches` from the same HelmRelease.

A local Helm **post-renderer plugin** (`kustomize-postrender`) then applies those same Kustomize
patches during bootstrap, exactly as Flux's helm-controller would. So the `istio-cni`
`HOST_PROBE_SNAT_IP` patch ([ADR 0005](0005-istio-ambient-mesh-over-cilium.md)) and the coredns
JSON-logging patch are present at bootstrap and under Flux, from the same lines of YAML.

### Why mise

`mise` pins every tool used across node and cluster bootstrap (`talosctl`, `kubectl`, `helm`,
`helmfile`, `sops`, `yq`, `minijinja-cli`, `age`, …) and exposes the whole flow as discoverable
tasks (`bootstrap:cluster`, `bootstrap:base`, `bootstrap:apps`, `//talos:apply-node`, …). It also
sets `HELM_PLUGINS` so the post-renderer plugin is found. The result is a reproducible bootstrap
that does not depend on whatever versions happen to be on the operator's workstation.

## Rationale

- The fresh-cluster chicken-and-egg (no CNI, DNS, or Flux) makes a pre-GitOps step unavoidable; the
  only real question is whether that step drifts from steady state. Reading the _same_
  HelmRelease/OCIRepository manifests Flux uses makes drift structurally impossible, the first
  reconcile is a no-op, not a fight.
- Pinning every tool with mise makes the bootstrap reproducible across operators and over time; a
  bootstrap that depends on whatever versions happen to be on the workstation is not reproducible.
- Installing CRDs up front is what lets controllers register webhooks during install and lets the
  Flux dependency graph stay lean (the premise of [ADR 0004](0004-prune-crd-dependencies.md)).
- Keeping the bootstrap set tiny (CNI, DNS, image cache, Flux) means everything else is ordinary
  GitOps; there is no second, divergent delivery path to maintain.

## Consequences

- **No bootstrap-vs-runtime drift.** Because versions/values/patches are read from the GitOps
  manifests, the first Flux reconcile is a no-op, not a fight.
- **Deterministic and reproducible.** Pinned tools + idempotent, re-runnable mise tasks make a
  rebuild boring.
- **CRDs-up-front** cleanly enables the dependency simplification in [ADR 0004](0004-prune-crd-dependencies.md).
- The bootstrap set is intentionally tiny (CNI, DNS, image cache, Flux); everything else is
  normal GitOps.
- The `.gotmpl` indirection (helmfile reaching into app manifests) is clever but non-obvious;
  a newcomer has to learn that helmfile is not the source of truth, the HelmReleases are.
- Bootstrap correctness depends on the app manifests keeping their expected shape
  (`ocirepo.yaml` + `helmrelease.yaml` at the conventional path); a layout change can break the
  templating silently.
- Two rendering engines (helmfile's Helm post-renderer plugin vs Flux's helm-controller) must
  stay behavior-compatible; a divergence in how patches apply would reintroduce drift.
- SOPS-encrypted secrets needed during bootstrap (flux operator/instance secrets, GCP KMS
  credential) are decrypted by pre-sync hooks, mirroring Flux's own SOPS decryption later.

## Alternatives considered

- **`flux bootstrap` (the built-in):** standard, but installs Flux with its own defaults and does
  not solve the pre-Flux CNI/DNS/image-cache layer, nor the single-source-of-truth-for-values goal.
- **A hand-run ordered `kubectl apply` / shell script:** simplest to start, but drifts from the
  HelmRelease values immediately and has no version pinning or idempotency guarantees.
- **Duplicating values into Helmfile:** would work, but creates exactly the two-sources-of-truth
  divergence this decision exists to prevent.
