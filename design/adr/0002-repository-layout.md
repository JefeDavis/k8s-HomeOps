# ADR 0002: Repository layout

## Context

The whole cluster is driven by GitOps: one repository is the single source of truth, and Flux
reconciles it continuously. A layout is needed that:

- makes "what runs where" obvious from the directory tree,
- keeps per-app concerns (workload, network policy, admission exceptions, backup) together,
- lets cross-cutting patterns (PVC backup, Postgres backup) be written once and reused,
- and lets the same manifests feed **both** the fresh-cluster bootstrap and steady-state Flux,
  so the two can never disagree (see [ADR 0003](0003-bootstrap-with-helmfile-and-mise.md)).

## Decision

Adopt a fixed, namespace-first directory convention under `kubernetes/`, with reusable Kustomize
**Components** for cross-cutting patterns and a `_global` tree for cluster-wide objects. Node and
bootstrap concerns live outside `kubernetes/` (`talos/`, `bootstrap/`).

```
kubernetes/
├── apps/
│   ├── _global/                     # cluster-wide: priorityclasses/, networkpolicies/ (CCNPs)
│   └── <namespace>/
│       ├── namespace.yaml           # the Namespace (+ mesh/pod-security labels)
│       ├── kustomization.yaml       # per-namespace: Pre-Flux + Flux-Kustomization lists
│       └── <app>/
│           ├── ks.yaml              # Flux Kustomization(s) for this app
│           ├── app/                 # the workload (HelmRelease + OCIRepository, or manifests)
│           ├── _networkpolicies/    # CiliumNetworkPolicies: owned by the PARENT namespace
│           │                        #   kustomization, not this app's ks.yaml (see below)
│           ├── exceptions/          # Kyverno PolicyExceptions (optional)
│           └── database/            # cnpg Cluster + backup (optional)
├── components/                      # reusable Kustomize Components (volsync, cnpg)
└── ...
```

The conventions that make it work:

- **Per-namespace `kustomization.yaml` has two ordered lists.** A _Pre Flux-Kustomizations_
  block (the `Namespace`, any standalone resources, and the app's `_networkpolicies/`) is applied
  first; the _Flux-Kustomizations_ block lists each app's `ks.yaml`. Network policy and the
  namespace exist before the workload they govern.
- **Underscore-prefixed directories are owned by the parent, not the module.** A folder like
  `_networkpolicies/` (any `_`-prefixed dir) lives _inside_ an app's directory for locality, but it
  is deliberately **not** reconciled by that app's Flux `Kustomization`: `ks.yaml` points `path:`
  only at `app/`. It is listed in the **parent** namespace `kustomization.yaml`'s Pre-Flux block,
  so it is applied by the namespace kustomization, ahead of and independently from the app. The `_`
  prefix is the signal: _colocated with the module, owned by the parent_. This is exactly what
  guarantees policy-before-workload ordering, but it is a genuine gotcha: the app's `ks.yaml` does
  not manage `_networkpolicies/`, so changing the app's scope or suspending its Kustomization does
  not touch its policies, and unwiring them means editing the parent kustomization, not the app.
- **One app = one directory = one Flux `Kustomization`.** `ks.yaml` points `path:` at the app's
  `app/` subdir, carries `dependsOn`, `postBuild`, `wait`, and (standardized) a fixed field order:
  `targetNamespace, interval, path, components, prune, sourceRef, postBuild, wait,
  healthCheckExprs, dependsOn`. The metadata name uses the `&app` YAML anchor so the name is
  reused in `postBuild.substitute: { APP: *app }`.
- **Workloads are HelmRelease + OCIRepository.** Every app pins its chart in an `ocirepo.yaml`
  (OCI chart ref + tag) and configures it in `helmrelease.yaml` (`spec.values`, `postRenderers`).
  This pairing is deliberately the unit the bootstrap reads from too (see [ADR 0003](0003-bootstrap-with-helmfile-and-mise.md)).
- **Reusable Components** (`kubernetes/components/{volsync,cnpg}`) package a cross-cutting pattern
  once (restic PVC backup; Postgres `ObjectStore` + `ScheduledBackup` + mesh/netpol wiring) and
  are pulled into an app via `spec.components: [../../../../components/<name>]` with the specifics
  passed through `postBuild.substitute` (`APP`, `VOLSYNC_CLAIM`, `VOLSYNC_CAPACITY`,
  `CNPG_BUCKET`, …). The backup policy for twenty apps is one file, not twenty.
- **`_global`** holds the objects that are cluster-scoped by nature: `PriorityClass`es
  (`platform-critical/high/low`, `application-default`) and the clusterwide
  `CiliumClusterwideNetworkPolicy` baselines (`allow-dns`, `allow-ambient`,
  `allow-ingress-internal-gateway`, `allow-ingress-external-gateway`).
- **Separation of layers:** `talos/` (node machine config), `bootstrap/` (helmfile + mise),
  and `kubernetes/` (GitOps desired state) are distinct top-level trees for three distinct
  lifecycle stages.

## Rationale

- **The directory tree should be the inventory.** A fixed namespace → app → (workload, policy,
  exceptions, backup) shape makes "what runs where" legible without a tool, and every app is reasoned
  about the same way.
- **One HelmRelease + OCIRepository per app is an independent lifecycle.** Each app reconciles,
  retries, upgrades, drifts, and rolls back on its own; a failing app does not roll back the
  platform, and a transient webhook timeout retries just that release. This is also why even naked
  manifests ship through the same unit rather than a parallel Kustomization path, one
  ordering/health/drift model, not two.
- **Cross-cutting patterns belong in one place.** Reusable Components (`volsync`, `cnpg`) make the
  backup policy for many apps one file, not many, so a change lands everywhere at once.
- **Policy-before-workload is structural, not incidental.** The per-namespace kustomization's
  Pre-Flux block applies the namespace and `_networkpolicies/` ahead of the app, which is also why
  those `_`-prefixed dirs are parent-owned (a deliberate ownership split, and a documented gotcha).

## Consequences

- The tree _is_ the inventory: namespace → app → (workload, policy, exceptions, backup) is
  legible at a glance, and every app follows the same shape.
- Cross-cutting policy is DRY and consistent: backup/DB patterns live in one Component, so a
  change lands everywhere at once.
- Network policy and namespace ordering is structural, not incidental, the per-namespace
  kustomization guarantees policy-before-workload.
- The HelmRelease/OCIRepository pairing is a clean seam that bootstrap and Flux both consume,
  eliminating bootstrap-vs-runtime config drift ([ADR 0003](0003-bootstrap-with-helmfile-and-mise.md)).
- The convention is strict: new apps must follow the exact directory + file-name shape or the
  wiring (per-namespace kustomization, bootstrap templates) silently misses them.
- The deep relative Component paths (`../../../../components/...`) are fragile to directory moves.
- **Ownership is non-obvious:** `_`-prefixed directories sit inside an app yet are reconciled by
  the parent namespace kustomization, not the app's `ks.yaml`. The `_` prefix is the only cue, and
  mistaking a policy folder for app-owned leads to editing the wrong wiring.
- A single large repo couples everything's history; there is no per-app release isolation.
- Secrets are SOPS-encrypted files (`*.sops.yaml`) co-located with the app that needs them;
  decryption is handled centrally by Flux (see [ADR 0003](0003-bootstrap-with-helmfile-and-mise.md)).

## Alternatives considered

- **Flat per-app Helmfile/Kustomize with no namespace grouping:** simpler nesting, but loses the
  namespace-as-unit model and the clean place to hang per-namespace network policy ordering.
- **A chart-per-app or umbrella chart:** more encapsulation, but heavier to author and reason
  about than plain HelmRelease + OCIRepository, and harder to feed into a CRD-free bootstrap. An
  umbrella/subchart install also renders every component into a single Helm release Secret, which
  etcd caps near ~1 MiB; kube-prometheus-stack alone (hundreds of rules and dashboards) can exceed
  that, so the whole platform in one release is infeasible regardless of authoring cost. Per-app
  HelmReleases keep each release Secret small and independent, and give per-component `dependsOn`
  ordering, health gating, and drift correction that a flat subchart install cannot express.
- **Separate repos per domain (app-of-apps across repos):** stronger isolation, but overkill for
  a single homelab cluster and adds cross-repo coordination for no real benefit here.
