# ADR 0012: ServiceAccount tokens are not auto-mounted; workloads project them

## Context

By default, Kubernetes auto-mounts a ServiceAccount token into every pod: a long-lived credential,
accepted by the generic API audience, present even in workloads that never call the API server.
That is a standing credential and a standing liability on every pod, the opposite of a
least-privilege posture. A workload that genuinely needs API access should carry a short-lived,
narrowly-scoped token, and everything else should carry none.

## Decision

Disable automatic token mounting everywhere, and have the workloads that need API access mount a
projected, short-lived token instead.

- **`automountServiceAccountToken: false` on both the ServiceAccount and the pod spec** of every
  platform workload.
- **Workloads that call the API server mount a projected token volume** at the standard path
  (`/var/run/secrets/kubernetes.io/serviceaccount`), with `expirationSeconds: 3607` (~1 hour), the
  `kube-root-ca.crt` ConfigMap, and the namespace via the downward API.
- **Delivered two ways, consistently.** The `FluxInstance` patches every Flux controller (automount
  off on the SA, projected volume + mount on the Deployment); each platform HelmRelease then repeats
  the same pattern through chart values, cert-manager, external-secrets, cilium (all four SAs),
  coredns, alloy, envoy-gateway, cnpg, istio, and more, roughly two dozen workloads in total.

## Rationale

- **Secure by default, not secure-if-excepted.** The baseline is "no standing token." A mounted
  credential becomes a deliberate, visible opt-in on the one workload that needs it, so the audit
  surface is the short list of things that _do_ mount a token, not every pod in the cluster.
- **Short-lived and audience-scoped beats long-lived and generic.** A projected token is
  time-bounded (`expirationSeconds`) and expires out from under a leak; the legacy auto-mounted
  token is long-lived and broadly accepted. The projected pattern matches the keyless, short-
  credential posture used elsewhere (SOPS + external-secrets for application secrets).
- **Patching only the pod is insufficient.** The ServiceAccount object itself must also set
  `automountServiceAccountToken: false`, or anything that references the SA directly can still be
  handed a token. Both are patched for that reason.

## Consequences

- No workload carries a standing API credential it does not use; the ones that do use short-TTL
  projected tokens that rotate roughly hourly.
- The pattern is uniform and visible in Git (the FluxInstance patch plus per-chart values), so the
  posture is auditable.
- A workload that silently relied on the auto-mounted token loses API access until it is converted
  to a projected volume; new apps must opt in deliberately.
- The projected-volume block is repeated across many charts, so consistency rests on convention and
  review rather than enforcement. A fleet-wide Kyverno policy that requires
  `automountServiceAccountToken: false` (rolled out `audit` first, then flipped to `enforce` with an
  empty exception set) is the natural next step.

## Alternatives considered

- **Per-ServiceAccount exceptions (mount by default, carve out the sensitive ones).** Inverts the
  audit surface: "token mounted" becomes the default and the exception list is the thing to audit,
  the opposite of secure-by-default.
- **Rely on the restricted Pod Security Standard alone.** Insufficient: PSS does not govern token
  auto-mount, so a restricted pod still receives a standing token.
- **Disable the token controller cluster-wide.** Too blunt: it breaks workloads that legitimately
  need API access and offers no per-workload scoping or expiry.
