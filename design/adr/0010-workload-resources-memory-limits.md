# ADR 0010: Workload resource requests and memory-only limits

## Context

Every workload shares the same three nodes. Two things can go wrong without resource discipline: a
pod with no requests is scheduled as `BestEffort`, gets no placement guarantee, and is first to be
evicted under pressure; and a pod with no memory limit can consume a node's memory until the
kubelet evicts its neighbors or the node goes `NotReady`. At the same time, a carelessly applied
CPU limit throttles a container that is doing useful work (a reconcile loop, a data-plane proxy)
for no stability benefit. The cluster needs a single, consistent rule for requests and limits.

## Decision

Set requests on every container and a memory limit on every container, and do not set CPU limits.

- **Requests (CPU + memory) on every container**, so every pod is at least `Burstable` with a real
  scheduling guarantee.
- **A memory limit on every container**, so no single workload can drive a node into memory
  pressure.
- **No CPU limit.** Where an upstream chart ships one, strip it: the Flux controllers have their
  CPU limit removed by a `FluxInstance` patch (`op: remove .../resources/limits/cpu`), and kyverno
  has its CPU limits nulled by a `postRenderer`.
- **Respect complete upstream chart defaults**; override only to add missing requests/memory limits
  or to remove a CPU limit.
- **Narrow, deliberate exceptions keep a CPU limit** where it is a conscious choice: coredns
  (`300m`) and the rook-ceph CSI components.

## Rationale

- **Memory is the only non-compressible resource, so a memory ceiling is non-negotiable.** A pod
  with no limit can starve every neighbor and take the node to `NotReady`. CPU contention is
  survivable (the scheduler time-slices); memory pressure is fatal, so the memory limit is the one
  that protects node stability.
- **A CPU limit is counterproductive.** Throttling a container that is under its memory limit and
  doing real work only hurts tail latency and adds no stability. CPU contention is meant to be
  arbitrated by requests (the scheduler's share mechanism), not by a hard ceiling. Throttling
  reconcile loops (Flux, kyverno) is exactly the pathology to avoid, which is why their
  chart-shipped CPU limits are explicitly stripped.
- **Requests are the scheduler's contract.** Without them a pod is `BestEffort` with no placement
  guarantee and is evicted first; carrying requests makes placement deterministic and eviction
  order predictable (reinforced by the priority tiers in [ADR 0011](0011-priority-classes.md)).

## Consequences

- Deterministic scheduling and node stability: every pod has a placement guarantee and a memory
  ceiling, so no workload can memory-starve a node.
- Reconcilers and data-plane pods run without CPU throttling, so latency is not sacrificed for a
  non-benefit.
- A memory limit set too low `OOMKill`s the workload, so values must track measured usage rather
  than guesses, and need revisiting as footprints grow with cluster density.
- The "no CPU limit" rule lives in two mechanisms (omit at the source, or patch-strip a chart
  default), so enforcing it on a new chart is a manual step that is easy to forget.
- The exceptions (coredns, CSI) mean the rule is "no CPU limit except where deliberately chosen,"
  which must be documented so the exceptions are not mistaken for oversights.

## Alternatives considered

- **Admission-time enforcement (a Kyverno `require-requests-and-memory-limit` policy).** Convention
  plus review is simpler for a single-maintainer repo; enforcement can be added later if drift
  appears.
- **CPU limits for "fairness."** Rejected: requests already arbitrate CPU contention via scheduler
  shares; a hard ceiling only throttles and never improves stability.
- **Vertical Pod Autoscaler auto-tuning.** Out of scope; requests are sized statically from
  measured usage and revisited only when usage diverges materially.
