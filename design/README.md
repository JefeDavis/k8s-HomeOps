# Design

Design documentation for this cluster.

- **[reference-architecture.md](reference-architecture.md)** is the living top-level reference:
  what the cluster is, how it functions, and the design decisions per domain (platform, network,
  mesh, ingress, storage, observability, security, GitOps). Start here.
- **[observability-architecture.md](observability-architecture.md)** is the deep dive for the
  observability domain: the Alloy collector, the metrics/logs/traces backends, Grafana, and the
  log-processing pipeline (parsing, `_msg`/stream fields, per-pod format routing). Linked from
  reference-architecture section 7.
- **[adr/](adr/)** holds the Architecture Decision Records: one file per significant decision,
  capturing the context, the decision, its rationale, consequences, and the alternatives considered.

## Architecture Decision Records

| ADR                                                         | Title                                                              |
| ----------------------------------------------------------- | ------------------------------------------------------------------ |
| [0001](adr/0001-use-talos-linux.md)                         | Talos Linux as the node operating system                           |
| [0002](adr/0002-repository-layout.md)                       | Repository layout                                                  |
| [0003](adr/0003-bootstrap-with-helmfile-and-mise.md)        | Bootstrap with Helmfile and mise                                   |
| [0004](adr/0004-prune-crd-dependencies.md)                  | Prune CRD-ordering dependencies from Flux Kustomizations           |
| [0005](adr/0005-istio-ambient-mesh-over-cilium.md)          | Istio ambient mesh over Cilium mesh                                |
| [0006](adr/0006-gateway-api-ingress-with-coraza-waf.md)     | Gateway API ingress with ListenerSets and the Coraza WAF           |
| [0007](adr/0007-volsync-to-kopiur-migration.md)             | Migrate PVC backup from Volsync to Kopiur (in progress)            |
| [0008](adr/0008-loki-to-victoria-logs.md)                   | Victoria Logs over Loki for log storage                            |
| [0009](adr/0009-ha-pdb-and-topology-spread.md)              | High availability: PodDisruptionBudgets and topology spread        |
| [0010](adr/0010-workload-resources-memory-limits.md)        | Workload resource requests and memory-only limits                  |
| [0011](adr/0011-priority-classes.md)                        | Platform PriorityClasses for scheduling precedence                 |
| [0012](adr/0012-serviceaccount-token-automount-disabled.md) | ServiceAccount tokens are not auto-mounted; workloads project them |
| [0013](adr/0013-structured-log-parsing-and-routing.md)      | Per-pod annotations drive structured log parsing in Alloy          |

## Conventions

- ADRs are numbered sequentially (`NNNN-kebab-title.md`) and are append-only: supersede an old
  decision with a new ADR rather than rewriting history.
- Each ADR has the same sections: **Context → Decision → Rationale → Consequences → Alternatives
  considered**. There is no status/date/author header: this is a single-maintainer repo, so git
  history carries the "who" and "when," and a decision's current standing lives in its prose
  (e.g. 0007 is in progress).
- The reference architecture links out to the ADR that justifies each design decision; ADRs link
  back to the relevant reference-architecture section and to related ADRs.
