# ADR 0014: Label and annotation namespace under `home.arpa`

## Context

Kubernetes namespaces a custom label or annotation key by a DNS-subdomain prefix (the part before
the `/`). The cluster's own conventions had drifted: most keys sat under `homeops.io`
(`ingress.gateway.homeops.io/internal`, `egress.homeops.io/minio`, `logging.homeops.io/format`,
`observability.homeops.io/prometheus-scrape`, `egress.vpn.homeops.io/enabled`), but at least one had
leaked onto a second domain (`egress.networking.io/object-store`). Two problems follow from this:

- **Collision risk.** `homeops.io` and `networking.io` are real, registrable domains. The whole
  point of a DNS-subdomain prefix is to namespace by something you control; a prefix on a domain you
  do not own can overlap with whatever a real registrant (or another tool) puts there.
- **Inconsistency.** Two base domains and ad-hoc sub-structures (`gateway.`, `vpn.`, `logging.`,
  `observability.`) made the keys hard to grep, hard to extend, and easy to spell differently in the
  selector than on the workload.

## Decision

Namespace every cluster-authored label and annotation under **`home.arpa`**, the domain RFC 8375
reserves for residential/home networks, with two structured sub-schemes.

- **Network-policy opt-in:** `<direction>.policy.home.arpa/<target>`
  - `<direction>` is `ingress` or `egress` (which way the flow the label gates runs).
  - `<target>` is the peer the policy allows: `internal-gateway`, `external-gateway`, `vpn`, `rgw`,
    `minio` (extend as needed).
  - Value is `"true"` / `"false"`.
- **Observability:** `<signal>.observability.home.arpa/<key>`
  - `<signal>` is `metrics`, `logs`, or `traces` (mirroring the three Alloy collectors).
  - e.g. `logs.observability.home.arpa/format`, `metrics.observability.home.arpa/prometheus-scrape`.
- **Kubernetes-standard keys are left alone** (`app.kubernetes.io/*`, `policies.kyverno.io/*`,
  `gateway.networking.k8s.io/*`, and other upstream-owned prefixes).

Mapping applied in this pass:

| Old key                                      | New key                                             |
| -------------------------------------------- | --------------------------------------------------- |
| `ingress.gateway.homeops.io/internal`        | `ingress.policy.home.arpa/internal-gateway`         |
| `ingress.gateway.homeops.io/external`        | `ingress.policy.home.arpa/external-gateway`         |
| `egress.vpn.homeops.io/enabled`              | `egress.policy.home.arpa/vpn`                       |
| `egress.homeops.io/minio`                    | `egress.policy.home.arpa/minio`                     |
| `egress.networking.io/object-store`          | `egress.policy.home.arpa/rgw`                       |
| `logging.homeops.io/format`                  | `logs.observability.home.arpa/format`               |
| `observability.homeops.io/prometheus-scrape` | `metrics.observability.home.arpa/prometheus-scrape` |

## Rationale

- **A reserved domain cannot collide.** `home.arpa` (RFC 8375) is never delegated to a registrant,
  so a prefix under it is guaranteed unique to this cluster forever. `homeops.io`/`networking.io`
  carry no such guarantee, which is precisely the overlap this change removes. It is also
  non-identifying, so it survives any later scrub of owned domains.
- **The scheme encodes intent in the structure.** For policy labels, the direction lives in the
  prefix and the peer in the key, so a selector reads unambiguously (`egress.policy.home.arpa/rgw`
  is "may egress to the RGW") and a new peer is a new key, not a new invented prefix. For
  observability, grouping by signal (`metrics`/`logs`/`traces`) mirrors the collector split so each
  Alloy instance owns its own namespace.
- **One standard keeps both sides aligned.** These keys live on the workload (as a label) and in the
  Cilium policy (as a selector, in `k8s:` form). A single documented convention makes the producer
  and the selector spell the key the same way and keeps the whole set greppable under one domain.

## Consequences

- Custom keys can no longer collide with a registered domain, and the full set is consistent and
  greppable under `home.arpa` (networking under `policy.home.arpa`, telemetry under
  `observability.home.arpa`).
- A rename is a coordinated both-sides change: the selector in a Cilium policy and the label on the
  workloads it selects must move together. Flux applies them in one reconcile, but because policy is
  default-deny there is a brief converge window where a half-renamed key would drop traffic, so the
  producer and selector edits ship in the same change.
- Upstream `app.kubernetes.io/*` and other vendor-owned keys are untouched, so this is additive to,
  not a replacement for, standard labels.
- New labels and annotations must follow the scheme; anything that needs a prefix outside
  `policy.`/`observability.` adds a new second level under `home.arpa` rather than a new domain.

## Alternatives considered

- **Keep `homeops.io` (treat it as the owned namespace).** Only safe if the domain is actually
  owned and kept owned; a registrable prefix is exactly the collision surface this ADR closes, and
  it re-introduces an identifying domain into every manifest.
- **`.internal` (ICANN-reserved private-use TLD).** Also collision-proof, but `internal` already
  appears as a label _value_ (`internal`/`external` gateways) and as a hostname label
  (`internal.${DOMAIN}`), and it sits awkwardly next to `svc.cluster.local`; the overloading invites
  confusion.
- **A bare token (`homeops`) or `.local`.** `.local` is reserved for mDNS (RFC 6762) and would be
  semantically wrong; a bare single-label token is not a reserved namespace and offers no collision
  guarantee.
