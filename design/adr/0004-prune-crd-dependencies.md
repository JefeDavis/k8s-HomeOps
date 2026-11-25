# ADR 0004: Prune CRD-ordering dependencies from Flux Kustomizations

## Context

Across the repo, many Flux `Kustomization`s carried `dependsOn` entries whose only purpose was to
wait for a **Custom Resource Definition** to exist before applying a custom resource:

- Anything shipping a `ServiceMonitor` / `PodMonitor` / `PrometheusRule` depended on
  `kube-prometheus-stack-crds`, the single most-used edge in the graph (~20 Kustomizations).
- Anything shipping a `GrafanaDashboard` / `GrafanaDatasource` / `Grafana` CR depended on
  `grafana-operator`.

These edges exist because applying a CR before its CRD is registered fails the Kustomization. But
they conflate two different things, _"the CRD must exist"_ and _"this component must run first"_,
and they impose real ordering cost: for example, **cilium** (the CNI) was waiting on an
observability CRD release before it could reconcile, which is backwards for a core component.

The premise changed with the bootstrap design ([ADR 0003](0003-bootstrap-with-helmfile-and-mise.md)):
`bootstrap/helmfile/crds.yaml` installs the CRDs for **envoy-gateway, grafana-operator,
kube-prometheus-stack-crds, and kyverno** up front, before Flux ever runs, and the corresponding
Flux Kustomizations keep those CRDs reconciled thereafter. So by the time any Flux Kustomization is
applied, those CRDs are already present. The `kube-prometheus-stack-crds` release in particular is
a **CRD-only** release, depending on it only ever meant "wait for CRDs," which is now guaranteed.

## Decision

Remove every `dependsOn` that existed **solely** to guarantee a bootstrap-installed CRD is present.
Concretely, strip all `dependsOn` references to `kube-prometheus-stack-crds` and to
`grafana-operator` (used for CRD availability) across the repo, the ones recently added during the
dependency-tree pass and the pre-existing ones alike, for consistency. Where removing an entry
empties a `dependsOn` block, remove the block.

Keep every `dependsOn` that encodes a **genuine runtime ordering or data dependency**, e.g.:

- route → `gateways` (an `HTTPRoute`/`TCPRoute` must bind to an existing Gateway/ListenerSet),
- workload → `rook-ceph-cluster` (needs the ceph StorageClass before its PVC binds),
- the istio chain (`istio-crds → istio → istio-cni → istio-ztunnel`), mesh deps on `istio-ztunnel`,
  `snapshot-controller`, `cert-manager-config`, database deps on `cloudnative-pg`, etc.

Net effect: 36 `dependsOn` entries removed across 22 Kustomizations (27 × `kube-prometheus-stack-crds`,
9 × `grafana-operator`). Several core components (cilium, coredns, kyverno, reloader, spegel,
cert-manager) now have **no** Flux dependencies and reconcile immediately.

## Rationale

- A `dependsOn` edge should mean "I need this component running," not "I need a CRD that happens to
  be registered." Conflating the two is what made cilium (the CNI) wait on an observability CRD
  release before it could reconcile, which is backwards.
- Because bootstrap guarantees the CRDs exist before Flux ever runs, the CRD-ordering edges carry
  zero information; removing them makes the graph express only real runtime dependencies and lets it
  converge faster and more in parallel.
- The guarantee does not disappear, it moves from being re-encoded on every CR-shipping
  Kustomization to one well-understood place (the bootstrap CRD set). One place to reason about
  beats dozens of redundant edges.

## Consequences

- A leaner, more honest dependency graph: an edge now means "I actually need this running," not
  "I need a CRD that already exists." Verified **acyclic** after the change.
- Core components no longer wait on unrelated releases, the CNI, DNS, and policy engine reconcile
  without a detour through observability CRDs.
- Faster, more parallel convergence; fewer artificial serialization points.
- **The guarantee now lives in bootstrap, not in the graph.** Correctness depends on
  `bootstrap/helmfile/crds.yaml` installing those CRDs first. If someone adds a new CR-shipping app
  whose CRD is _not_ bootstrapped, or removes a CRD from the bootstrap set, the missing
  `dependsOn` will bite as a reconcile failure. This coupling must be understood (hence this ADR).
- **Eventual-consistency corner.** `grafana-instance` and the dashboard/datasource-shipping apps no
  longer wait on `grafana-operator`, so a `Grafana`/`GrafanaDashboard` CR may sit unreconciled
  briefly until the operator pod is up. This is standard GitOps eventual consistency, not a failure,
  but it means "applied" no longer implies "reconciled by the operator" for those objects.
- The `kube-prometheus-stack-crds` and `grafana-operator` Kustomizations still exist and still
  manage the CRD lifecycle under Flux; only the _edges pointing at them_ were removed.

## Alternatives considered

- **Keep the CRD `dependsOn` edges:** safe and explicit, but redundant given bootstrap, and it
  keeps the CNI (and others) needlessly waiting on observability CRDs.
- **Only remove the edges just added, keep the pre-existing ~20:** inconsistent, it would leave 20
  identical, equally-redundant edges in place while removing 7, for no principled reason.
- **Rely on Flux health-retry instead of ordering at all (everywhere):** Flux does retry a failed
  apply, so CRs would eventually succeed once CRDs/operators exist, but leaning on retry for
  _known_ ordering (storage, gateways, mesh) produces noisy transient failures; those edges stay.
