# ADR 0008: Victoria Logs over Loki for log storage

## Context

Logs were previously stored in **Grafana Loki** (single-binary, in the old `monitor` namespace,
now under `archive/`), fed by the log collector and queried from Grafana. Loki works, but for a
small single-cluster homelab it carries friction disproportionate to the scale:

- **Operational weight for HA.** Loki's distributed/HA modes need a shared object store and several
  coordinated components; single-binary is the honest mode at this size, but then you are running a
  system designed to scale out in its least-scaled configuration.
- **Index/label model.** Loki's performance hinges on disciplined label cardinality; it is easy to
  create slow queries or ingestion pressure with a label set that seems reasonable.
- **Resource footprint** relative to the volume of logs a three-node homelab actually produces.

**Victoria Logs** targets exactly this niche: a single, lightweight binary with low resource use,
a simpler operational model, good compression, and **LogsQL**. Critically, it exposes a
**Loki-compatible ingestion endpoint**, so the collector side does not have to be rewritten to move.

## Decision

Replace Loki with **Victoria Logs** as the log store.

Concrete shape:

- **Victoria Logs** (`victoria-logs-single` chart `0.13.13`) as a single-binary `StatefulSet` in
  `observability`, backed by a `ceph-block` PVC (20Gi) with **30-day** retention.
- **Ingestion unchanged in spirit:** `alloy-logs` (the per-node DaemonSet) tails pod logs and pushes
  to Victoria Logs over its **Loki-compatible** HTTP endpoint
  (`:9428/insert/loki/api/v1/push`, with `_stream_fields` for cluster/namespace/app/container/stream).
  Because the endpoint speaks the Loki push protocol, the collector pipeline moved with a config
  change, not a re-architecture.
- **Query via Grafana** using the `victoriametrics-logs-datasource` plugin (auto-installed on the
  Grafana instance), querying LogsQL over `:9428`. A direct Victoria Logs UI is exposed internally
  at `vlogs.internal.${DOMAIN}`.
- Victoria Logs exposes `/metrics` and is scraped like everything else; Loki and its datasource were
  removed from the active tree (the old setup remains under `archive/` for reference).

This sits in the broader observability split: **Alloy** collects all three signals:
`alloy-metrics` (remote-writes to the kube-prometheus-stack Prometheus), `alloy-logs` (to Victoria
Logs), `alloy-traces` (OTLP to Tempo), so swapping the log _store_ is a localized change to one
backend and one Alloy endpoint.

## Rationale

- Loki's value is horizontal scale-out; at homelab log volume that value is unrealized, and
  single-binary Loki means running a system designed to scale in its least-scaled mode, carrying the
  label-cardinality discipline without the payoff.
- Victoria Logs is a single lightweight binary with a lower footprint and good compression, matched
  to the actual scale.
- The Loki-compatible ingestion endpoint is the decisive factor: it turns the migration into a
  one-line change on the Alloy collector rather than a re-architecture, which de-risks the swap.
- Grafana remains the query surface, so the only user-facing change is the query language (LogsQL vs
  LogQL), a one-time cost largely absorbed because dashboards are re-provisioned as code.

## Consequences

- **Lower operational and resource footprint** for the same job: one small binary, simpler to run
  and reason about than Loki at this scale.
- **Cheap migration path** thanks to the Loki-compatible ingestion API, the Alloy log pipeline
  barely changed, and Grafana remains the query surface.
- Good compression and straightforward retention on a single ceph-block PVC; LogsQL is ergonomic for
  the common "filter by stream fields, grep the message" query.
- **Smaller ecosystem/community** than Loki; fewer dashboards, integrations, and
  Stack-Overflow-answers. Some Grafana log features are Loki-shaped and may differ.
- **LogsQL is a different query language** from LogQL; existing Loki queries/dashboards must be
  re-expressed (a one-time cost, largely absorbed since dashboards are re-provisioned).
- **Single-binary = single point of storage** for logs (one PVC, one replica). Acceptable for a
  homelab, but there is no log-store HA; loss of the PVC loses recent logs within retention.
- Dependence on Victoria Logs maintaining its Loki-compatibility surface for the ingestion path.

## Alternatives considered

- **Stay on Loki (single-binary):** no migration cost, but keeps the operational weight and
  label-cardinality care that motivated the move, at a scale that does not benefit from Loki's
  scale-out design.
- **Loki distributed + object store (rook-ceph S3):** the "proper" Loki HA shape, but materially
  more components and moving parts than a homelab log volume justifies.
- **OpenSearch / Elasticsearch:** powerful search, but a heavyweight JVM stack and far more
  operational surface than needed here.
