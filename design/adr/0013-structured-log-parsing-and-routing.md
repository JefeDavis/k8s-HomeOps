# ADR 0013: Per-pod annotations drive structured log parsing in Alloy

## Context

`alloy-logs` (the per-node DaemonSet) tails every pod's stdout/stderr and pushes to Victoria Logs
over the Loki-compatible endpoint (ADR 0008). Victoria Logs **auto-parses a JSON log line** on
ingest, flattening it into queryable fields, so for the many workloads that emit JSON the pipeline
needs to do almost nothing. The rest of the fleet does not emit JSON, and it does not emit one single
non-JSON format either: there is klog (`I1124 …] msg`), the Ceph daemon format
(`debug <ts> <thread> <lvl> msg`), zap console (tab-delimited `ts⇥LEVEL⇥logger⇥msg⇥{json}`), nginx
access logs, logfmt, and a long tail of app-specific text.

Two problems follow. First, without help Victoria Logs stores a non-JSON line verbatim and leaves the
`_msg` field unset (its message-field heuristic only fires for recognized shapes), so the headline
field is empty and the level is unqueryable. Second, parsing these formats means running the right
transform on the right logs — and deciding "which parser" by **content sniffing** (regex that tries to
recognize each format) or by **namespace** is fragile: it mis-fires on edge cases, couples the
pipeline to where things happen to run, and does not scale as apps come and go.

We want each workload to state, declaratively, what it logs, and have the collector route on that
statement — the pattern Fluent Bit established with its `fluentbit.io/parser` pod annotation.

## Decision

A pod annotation names the log format; `alloy-logs` routes to the matching parser by that annotation.

- **Annotation:** `logs.observability.home.arpa/format`. `alloy-logs`' `discovery.relabel` maps
  `__meta_kubernetes_pod_annotation_logs_observability_home_arpa_format` to an internal `log_format` label,
  which `stage.match` selects on. The label is dropped (`stage.label_drop`) before the write, so it
  routes but is never stored.
- **JSON is the default.** A pod with no annotation is treated as JSON and left to Victoria Logs'
  ingest-time parser. Only non-JSON pods are annotated, which keeps the common case zero-config.
- **Universal pre-processing**, applied to every line before routing: `stage.cri` (strip the
  containerd wrapper, set the timestamp), then `stage.decolorize` (strip ANSI color so colored logs
  don't poison `_msg` or defeat a parser's regex).
- **`_msg` is fixed globally** on the write endpoint with `_msg_field=msg,message,fields.message,@mt`:
  Victoria Logs uses the first present field as `_msg` for JSON logs (covering Go `msg`, others'
  `message`, Rust `tracing`'s nested `fields.message`, Serilog `@mt`), and falls back to the raw line
  for plain text. This handles JSON apps whose message is nested (e.g. kopiur and other `tracing`
  apps) without a dedicated parser.
- **Starting parser set:** `json` (default), `logfmt`, `klog`, `ceph`, `zap`, `nginx`, `cnpg`
  (CloudNativePG wraps Postgres logs as JSON with the real message nested under `record.message` and
  `msg` set to the literal `"record"`; the parser lifts it out via JMESPath coalescing
  `record.message || msg` and promotes `record.error_severity` → `level`), and `starr` (the Servarr
  `[Level] Logger: message` NLog console format shared by the *arr apps; a non-destructive regex
  extracts `level`/`logger` and strips the prefix, so it leaves .NET stack-trace continuation lines
  intact). Anything else is annotated `plain` — a documentary value with no parser, so `_msg` is the
  raw (decolorized) line.
- **Level without cardinality cost.** Parsers extract `level` (and a couple of other low-cardinality
  fields) into **Loki structured metadata**, which Victoria Logs stores as ordinary non-stream
  fields. Nothing parser-extracted becomes a stream field.

## Rationale

- **Declarative beats heuristic.** The format is the workload's own declaration in Git, not a guess
  the collector makes per line. It is self-documenting (the annotation _is_ the format inventory) and
  it extends by adding one `stage.match` plus one annotation, with no change to existing routes.
- **Anchored, scoped parsers can't mis-fire.** Because a parser only runs inside
  `stage.match {log_format="x"}`, every line it sees really is that format, so it can use a
  destructive transform (`stage.output`) safely; there is no risk of a klog regex mangling a Ceph line.
- **JSON-default matches reality.** Most of the fleet already emits JSON and Victoria Logs already
  parses it; making that the no-annotation path means the annotation effort is confined to the
  shrinking set of non-JSON apps.
- **Structured metadata, not labels, for `level`.** Fields like `level` are useful to filter on but
  must not fragment the log streams; structured metadata gives queryable fields while
  `_stream_fields` stays limited to `cluster,namespace,app,container,stream`.
- **ANSI is stripped once, centrally.** Color codes are a cross-cutting nuisance (they corrupt `_msg`
  and break regexes); a single `stage.decolorize` ahead of routing fixes it for every format at once.

## Consequences

- Non-JSON workloads carry an explicit `logs.observability.home.arpa/format` annotation; JSON workloads carry
  none. The set of annotations is the cluster's log-format inventory, visible in Git.
- `_msg` is populated across the fleet and `level` is a queryable field for the parsed formats, so
  "filter by level, grep the message" works uniformly in Grafana/vmui.
- Routing is **pod-level, not container-level**. A pod whose containers log in different formats
  (e.g. the managed Envoy gateway pods: JSON access logs from Envoy plus zap from the shutdown-manager
  sidecar) can only carry one annotation; the minority container falls back to raw `_msg`. Such pods
  are left on the JSON default.
- Operator-managed pods (Ceph daemons, CSI drivers) can't take a plain HelmRelease `podAnnotations`;
  they are annotated through their operator specs (`cephClusterSpec.annotations`, the CephFilesystem /
  CephObjectStore specs, the CSI driver specs), so the annotation lives a layer away from the pod.
- **Levels are normalized only where the native vocabulary isn't UI-recognized.** klog (`I/W/E/F`) and
  zap (`INFO/WARN/…`) keep their native values; Ceph's `DBG/INF/WRN/ERR` abbreviations are mapped to
  `debug/info/warn/error` because the Grafana/vmui level detector doesn't recognize them. Mapping uses
  `source`-scoped `stage.replace` (value substitution on the extracted field), not `stage.template` —
  the Alloy chart renders `configMap.content` through Helm's `tpl`, which would consume a template's
  `{{ … }}`.
- Maintenance rests on convention: an app that changes its log format needs its annotation updated,
  and a new non-JSON app needs one added, or it falls back to the JSON/raw default.

## Alternatives considered

- **Content sniffing (regex per format, no annotation).** The collector guesses the format from the
  line. Anchored regexes can be made safe, but ordering/precedence is fiddly, false matches are a
  standing risk, and there is no inventory of what logs as what — the knowledge is buried in pipeline
  regex instead of declared on the workload.
- **Namespace-scoped matches.** Simpler than annotations for a single-format namespace (the earlier
  rook-ceph approach), but it breaks down the moment a namespace mixes formats (rook-ceph itself runs
  Ceph daemons _and_ klog CSI drivers), and it couples parsing to placement.
- **Force every app to emit JSON.** Ideal where possible and done widely already, but impossible for
  some (Ceph daemons, kube-state-metrics' bare klog, proprietary apps), so a parsing path is needed
  regardless.
- **Query-time parsing only (`unpack_json`/`unpack_logfmt` in LogsQL).** Works for ad-hoc queries but
  gives no persistent fields: dashboards and alerts can't select on `level` without re-parsing every
  query, and `_msg` stays unset at rest.
