# ADR 0006: Gateway API ingress with ListenerSets and the Coraza WAF

## Context

North-south traffic (external client → in-cluster service) needs an ingress layer that is:
standards-based rather than vendor-locked; able to split **internal-only** from **internet-exposed**
exposure cleanly; able to grow new hostnames without editing one monolithic object; automatically
TLS-terminated; and protected at the edge against common web attacks and abusive bots.

The legacy Ingress API is underpowered (annotations-as-config, no good role split). An Istio
`Gateway` + `VirtualService` would couple north-south routing to the mesh vendor. The platform
already runs Istio ambient for _east-west_ ([ADR 0005](0005-istio-ambient-mesh-over-cilium.md)) and
deliberately does **not** want the ingress data plane welded to it.

## Decision

Use the **Gateway API** with **Envoy Gateway** as the data plane, split exposure into an internal
and an external Gateway, attach listeners via **ListenerSets**, and bind the **Coraza WAF** to the
external gateway.

### Data plane and gateways

- **Envoy Gateway** (`v1.10.0`) provides `GatewayClass: envoy`
  (`gateway.envoyproxy.io/gatewayclass-controller`), tuned by an `EnvoyProxy` (`envoy-config`):
  non-root/read-only Envoy, JSON access logs (matching the mesh log format), Prometheus metrics,
  and OTLP tracing to `alloy-traces`. Listeners run on standard ports (no 80→10080 remap needed).
- **Two Gateways in the `gateways` namespace**, each with a Cilium LB-IPAM VIP advertised by BGP
  ([reference-architecture](../reference-architecture.md)):
  - `internal-gateway`, internal/LAN-only hostnames.
  - `external-gateway`, internet-exposed hostnames.

### ListenerSets for scale-out hostnames

Rather than an embedded `servers`/listener list on each Gateway, each Gateway sets
`allowedListeners.namespaces.from: All` and the HTTPS listeners live in a separate **`ListenerSet`**
that attaches via `parentRef`:

- `internal` ListenerSet → `*.${DOMAIN}` and `*.internal.${DOMAIN}` on `:443`, TLS secret
  `internal-tls`.
- `external` ListenerSet → `*.${DOMAIN}` on `:443`, TLS secret `external-tls`.

Adding a domain or TLS listener is a new/edited ListenerSet, not surgery on the parent Gateway: the
role boundary (infra owns the Gateway; listeners/routes attach to it) is structural.

### TLS

cert-manager provisions the listener certificates. The ListenerSets are annotated
`cert-manager.io/cluster-issuer: letsencrypt-prod`; the `letsencrypt-prod` ClusterIssuer uses
**ACME DNS-01 via Cloudflare**, so wildcard certs are issued and rotated automatically without
exposing an HTTP-01 challenge path. TLS is always on for served hostnames.

### Backend opt-in (defense in depth with network policy)

A backend joins a gateway by **label**, and a clusterwide Cilium policy enforces that only that
gateway's Envoy pods may reach it:

- `ingress.gateway.homeops.io/internal: "true"` → `allow-ingress-internal-gateway` CCNP.
- `ingress.gateway.homeops.io/external: "true"` → `allow-ingress-external-gateway` CCNP.

So routing (Gateway API) and reachability (Cilium) agree by construction: a route to an un-labeled
backend is dropped by default-deny.

### Web application firewall (Coraza)

The **external** gateway (only) binds an `EnvoyExtensionPolicy` (`external-gateway-extensions`)
that loads **Coraza** as an Envoy dynamic module (`composer` / `coraza-waf`), running the **OWASP
Core Rule Set**:

- `SecRuleEngine On`, **active blocking**, not detection-only.
- OWASP CRS at **paranoia level 1**, anomaly thresholds inbound 5 / outbound 4; request-body
  inspection on, response-body off; streaming for oversized bodies.
- Credential-bearing fields (`password`, `client_secret`, `refresh_token`, `SAMLResponse`, …) are
  excluded from inspection so secrets are never logged by the WAF.
- A companion Lua filter blocks abusive crawler/AI user-agents (GPTBot, CCBot, Bytespider,
  Amazonbot, Meta-ExternalAgent, …).

Malicious requests are scored and dropped at the edge before reaching any backend. The internal
gateway runs without the WAF (trusted LAN origin, lower risk, lower latency).

## Rationale

- **The ecosystem speaks Gateway API.** Third-party charts overwhelmingly ship `HTTPRoute` (or the
  older Ingress), not Istio `VirtualService`; standardizing on the Gateway API means a chart's
  routing is consumed directly instead of hand-ported, and typed routes per protocol (`HTTPRoute`,
  `GRPCRoute`, `TCPRoute`, `TLSRoute`) all attach to the same Gateway/listener model.
- **Role separation shrinks blast radius.** The `GatewayClass → Gateway → HTTPRoute` split lets
  infrastructure own the listener/TLS surface while apps own their routes; a bad route change cannot
  take down the shared Gateway, a cleaner RBAC boundary than everyone editing one central object.
- **ListenerSets make a hostname a per-domain, per-cert, decoupled unit.** New domains attach as
  separate `ListenerSet` resources rather than mutating a monolithic `servers` list, so domains and
  their certs scale out independently, something the legacy Istio `Gateway` model cannot express.
- **One standardized policy-attachment model.** Edge concerns (cert-manager TLS, the Coraza WAF, and
  future auth) bind to a Gateway or route by `targetRef`, colocated with what they protect, and
  compose cleanly with mesh mTLS (workload identity, [ADR 0005](0005-istio-ambient-mesh-over-cilium.md))
  and Cilium policy (reachability) as distinct layers.
- **Blocking WAF at the edge, where the risk is.** The internet-facing gateway scores and drops
  malicious requests before any backend sees them; the internal gateway skips the WAF for lower
  latency on trusted-LAN traffic.

## Consequences

- Vendor-neutral, role-oriented ingress (`GatewayClass → Gateway → ListenerSet → HTTPRoute`); the
  data plane is swappable without rewriting application routes.
- Clean internal/external split with independent VIPs, TLS secrets, and WAF posture.
- New hostnames scale out via ListenerSets instead of contending on one central object.
- Automated wildcard TLS (DNS-01) and edge WAF blocking give authenticated-ish, hardened ingress
  by default; network-policy opt-in makes routing and reachability consistent.
- `ListenerSet` is a newer Gateway API surface; fewer examples and some implementation-specific
  behavior (`allowedListeners: All`) to keep in mind.
- The WAF is an Envoy **dynamic module** (Coraza via `composer`), a less common deployment than a
  managed WAF, rule tuning, body-buffering limits, and false positives are the operator's job.
- Running the WAF in blocking mode risks blocking legitimate traffic on a bad CRS match; mitigated
  by PL1 + credential exclusions, but it is a real tuning surface.
- Two gateways + ListenerSets + opt-in labels + clusterwide policies is more moving parts than a
  single Ingress controller.
- Exposure is via Cilium LB-IPAM + BGP to the local router (no external-dns / tunnel); DNS for the
  wildcard domains is managed at Cloudflare, which is also the ACME solver.

## Alternatives considered

- **Istio `Gateway` + `VirtualService`:** reuses the mesh, but locks north-south routing to Istio
  and keeps the ingress data plane coupled to the mesh vendor, the opposite of the goal.
- **ingress-nginx (Ingress API):** familiar and battle-tested, but the Ingress API is effectively
  frozen and expresses advanced routing and edge auth only through controller-specific annotations
  (a portability problem in a different shape), with no first-class multi-listener/ListenerSet model
  or typed per-protocol routes.
- **A managed/standalone WAF appliance:** stronger rule management, but adds an out-of-cluster hop
  and cost, and breaks the "everything is in-cluster GitOps" model for a homelab.
