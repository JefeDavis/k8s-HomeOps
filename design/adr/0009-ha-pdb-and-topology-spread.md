# ADR 0009: High availability by workload category: PodDisruptionBudgets and topology spread

## Context

The cluster has three nodes, and node drains are routine: every Talos or Kubernetes upgrade
([ADR 0001](0001-use-talos-linux.md)) cordons and drains a node in turn. A voluntary disruption
(a drain) must not take a platform service offline, and an involuntary one (a node loss) is
tolerated by the control-plane quorum. Without a deliberate HA posture, two failure modes appear:
a drain evicts the only replica of a critical service (an outage), or a `PodDisruptionBudget`
is mis-set on a single-replica workload and the drain hangs forever.

Not every workload deserves the same treatment. For a request-path service (DNS, the ingress data
plane, an admission webhook) absence is an immediate failure: DNS down means the API is broken.
For a reconciler (cert-manager, external-secrets, a Flux controller) a brief absence is only a
delay: desired state lives in Git or the API and re-converges. HA should be spent where absence
causes failures, not where it only causes delay.

## Decision

Give every platform workload a PDB, run the HA-critical categories with two or more replicas plus
hostname topology spread, and leave leader-elected reconcilers single.

- **A `PodDisruptionBudget` on every platform workload.**
  - Single-replica (leader-elected) controllers use `maxUnavailable: 1`, which permits the pod to
    be evicted so a drain makes progress.
  - Multi-replica fail-closed webhooks use `minAvailable: 1` (e.g. cert-manager and
    external-secrets webhooks, kyverno admission at 3 replicas), so admission always has a live
    backend.
- **Two or more replicas + topology spread for the HA-critical categories:** the request path and
  admission (coredns ×2, metrics-server ×2, the envoy-gateway data plane ×2, cert-manager webhook
  ×2, external-secrets ×2, kyverno admission ×3, istiod).
- **Topology spread across nodes** on every multi-replica Deployment:
  `maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `matchLabelKeys: [pod-template-hash]`,
  `whenUnsatisfiable: DoNotSchedule` (hard).
- **Single replica for leader-elected reconcilers** (cert-manager controller, external-secrets
  operator where applicable, the Flux controllers, reloader, resume operator), guarded only by the
  base PDB.
- **DaemonSets** (cilium, alloy-logs, spegel) are inherently one-per-node; cilium's PDB uses a
  percentage (`maxUnavailable: 25%`).

## Rationale

- **`maxUnavailable: 1` is the universally drain-safe PDB.** It lets a single-replica pod be
  evicted (so the drain progresses) while capping a multi-replica service to one disruption at a
  time. `minAvailable: 1` on a one-replica workload computes zero allowed disruptions and
  **deadlocks the drain indefinitely**, the classic single-replica PDB footgun; so single replicas
  use `maxUnavailable`, and `minAvailable` is reserved for fail-closed multi-replica webhooks.
- **Leader election makes a second replica optional for reconcilers.** Only one replica holds the
  lease, so the single thing a second replica buys, faster failover, does not matter for a
  reconciler (it is not serving requests). After a drain it simply re-acquires the lease and
  re-converges. Spending a second node slot on idle standby for every controller is HA where it is
  not needed.
- **Hard topology spread is safe here precisely because replica counts never exceed node count.**
  The reason elastic clusters must use soft spread (`ScheduleAnyway`) is that a hard constraint can
  wedge a pod `Pending` with no autoscaler to satisfy it. With at most three replicas on three
  nodes a valid zero-skew placement always exists, so `DoNotSchedule` cannot wedge, and it gives a
  firm one-replica-per-node guarantee instead of a mere preference.

## Consequences

- Every platform service survives a single-node drain (a rolling Talos/Kubernetes upgrade) without
  an outage.
- HA cost (a second replica) is spent only on the request path, admission, and ingest; leader-
  elected reconcilers stay single, so the three-node budget is not wasted on idle standbys.
- The posture is explicit and uniform: PDB values and topology spread are set in each app's chart
  values, visible in Git.
- Hard topology spread means any workload whose replica count exceeds the node count would wedge
  `Pending`; adding a fourth replica to a three-node cluster requires revisiting the constraint.
- The HA category of each workload is a judgment call that must be maintained as the app set grows.
- DaemonSet PDBs expressed as a percentage (cilium `25%`) behave differently from the
  count-based ones and are easy to overlook when reasoning about drains.
- Involuntary disruption (a node failing outright) is out of PDB scope; it is covered by the
  control-plane quorum tolerating one lost node and by the services already running two spread
  replicas.

## Alternatives considered

- **Two replicas for everything.** Wasteful on delay-tolerant reconcilers, and actively unsafe for
  leader-elected or single-writer workloads that cannot run active-active.
- **Soft topology spread (`ScheduleAnyway`) everywhere.** Unnecessary here: with replicas at most
  equal to node count, hard spread never wedges and buys a firmer guarantee. Soft spread would
  only matter if replica counts could exceed the node count.
- **Admission-time enforcement (a Kyverno policy that injects PDBs).** Less GitOps-visible, adds a
  runtime dependency, and unnecessary when the chart values already express the budget per app.
