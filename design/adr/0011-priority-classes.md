# ADR 0011: Platform PriorityClasses for scheduling precedence and eviction order

## Context

The cluster has three nodes and no autoscaler: capacity is fixed. When a node is under memory
pressure the kubelet must shed the right pods first, and when the scheduler queue is contended the
right pods must be placed first. Kubernetes decides both by pod priority, and the built-in
`system-node-critical` / `system-cluster-critical` classes only cover kube-system infrastructure.
Everything the platform runs on top (mesh, ingress, admission, reconcilers, observability, apps)
needs an explicit, intentional ordering, or the kubelet will make that choice arbitrarily.

## Decision

Define five cluster-scoped `PriorityClass`es in `kubernetes/apps/_global/priorityclasses/`, and
leave kube-system infrastructure on the built-in `system-*` classes.

| Class                    | value     | preemptionPolicy                | Members                                                                                                                                |
| ------------------------ | --------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `platform-node-critical` | 100001000 | `PreemptLowerPriority`          | node-pinned DaemonSets: cilium, alloy-logs, spegel                                                                                     |
| `platform-critical`      | 100000000 | `Never`                         | kyverno admission, istiod, the ingress data plane (gateways)                                                                           |
| `platform-high`          | 10000000  | `Never`                         | cert-manager, external-secrets, metrics-server, kyverno background/cleanup/reports, the envoy-gateway control plane, resume operator   |
| `application-default`    | 1000000   | `Never` (`globalDefault: true`) | application workloads (the default for any pod without an explicit class)                                                              |
| `platform-low`           | 100000    | `Never`                         | observability (prometheus, victoria-logs, tempo, grafana, alloy metrics/traces), backup (kopiur), the cnpg plugin, reloader, reflector |

- **Numbering mirrors the built-in pair one order of magnitude down** (`platform-node-critical` at
  100001000 sits 1000 above `platform-critical` at 100000000, the same gap the system classes use),
  leaving clean headroom. All custom values stay comfortably under the 1e9 ceiling the API enforces
  on custom classes.
- **Only `platform-node-critical` preempts;** every other custom class is `preemptionPolicy: Never`.
- **kube-system infrastructure keeps the built-in `system-*` classes** (cilium also carries
  `system-node-critical`; coredns, kubelet-csr-approver, and rook-ceph use `system-cluster-critical`);
  istio-cni and ztunnel default to `system-node-critical` upstream with no clean override and keep
  it.

## Rationale

- **Priority is an ordering backstop, not a capacity reservation.** These classes govern only the
  scheduler queue and the kubelet's eviction order; they reserve nothing. Capacity is managed by the
  node count and the resource budgets in [ADR 0010](0010-workload-resources-memory-limits.md).
- **`application-default` is deliberately placed between the platform runtime and the platform
  background.** It ranks _above_ `platform-low` so the kubelet sheds observability and backup before
  an application under memory pressure, and _below_ `platform-critical`/`platform-high` because
  applications depend on DNS, admission, identity, mesh, and ingress to function at all. It is the
  `globalDefault`, so a pod with no explicit class lands here.
- **Only node-pinned work preempts, because only it cannot be rescheduled elsewhere.** A DaemonSet
  pod must claim its slot on a specific node, so it preempts to get it. Every other tier is `Never`:
  with no autoscaler there is no new capacity to schedule a preempted victim onto, so preemption
  would only churn a lower-priority pod into `Pending` for no net gain, better to leave it running
  until a human adds capacity. The `platform-critical` members are all HA
  ([ADR 0009](0009-ha-pdb-and-topology-spread.md)), so a single `Pending` replica is already covered
  by its siblings.
- **Ingress data plane is critical; control planes are merely high.** The gateways carry live
  traffic, so their loss is an instant outage (`platform-critical`). The envoy-gateway control plane
  only stalls config changes when down (`platform-high`). The same logic puts reconcilers like
  cert-manager and external-secrets at `platform-high`: a brief outage is a slow burn (issued certs
  and synced secrets keep working), not an immediate failure.

## Consequences

- Under node pressure the kubelet sheds in a predictable, intentional order (background platform
  first, then apps, with the critical runtime plane last), and the scheduler queues the important
  pods first.
- The tiers compose with the HA posture ([ADR 0009](0009-ha-pdb-and-topology-spread.md)) and the
  resource rules ([ADR 0010](0010-workload-resources-memory-limits.md)) into one coherent scheduling
  story.
- A `PriorityClass`'s `.value` is immutable, so re-tiering a class is a delete-and-recreate
  operation, not an edit.
- The five classes are cluster-scoped objects that must be bootstrapped before any workload
  references them, or pods fail admission with an unknown-priority-class error; they live in
  `_global` and apply early for exactly this reason.

## Alternatives considered

- **`platform-critical` with preemption enabled.** Rejected: with no autoscaler, preemption cannot
  salvage a capacity crunch, it only evicts a lower-priority pod that then goes `Pending` itself.
  It adds churn without adding capacity, and the critical members are HA anyway.
- **A single tier, or relying on the default.** Loses the kubelet's ability to shed telemetry and
  backup before applications, and applications before nothing, which is the whole point.
- **Admission-time enforcement of per-workload priority.** Deferred; priority is set in each app's
  chart values and reviewed, which is sufficient for a single-maintainer repo.
