# ADR 0005: Istio ambient mesh over Cilium mesh

## Context

The cluster uses **Cilium** as its sole CNI, in **native routing** mode (no overlay):
`routingMode: native`, `autoDirectNodeRoutes: true`, `ipv4NativeRoutingCIDR` set to the pod CIDR,
kube-proxy replacement on (Talos ships no kube-proxy, per [ADR 0001](0001-use-talos-linux.md)).

East-west service traffic should be **encrypted and mutually authenticated by default**, with a
cryptographic workload identity, so that a compromised or unmeshed pod cannot read or spoof
service-to-service traffic. There are two credible ways to get this:

1. **Cilium's own transparent encryption** (WireGuard or IPsec) plus Cilium's identity model.
2. **A service mesh**, Istio, providing mTLS at the workload-identity (SPIFFE) layer.

Cilium transparent encryption secures the _node-to-node_ datapath but is not a
workload-identity mTLS story: it does not give per-service SPIFFE identities, STRICT
"plaintext-rejected" peer authentication, or an identity-based authorization substrate. The mesh
does, and it does so independently of the CNI, which keeps the two concerns cleanly separated:
Cilium stays a pure L3/L4 datapath + network-policy engine, Istio owns service identity and
in-transit encryption.

The historical cost of a mesh was the per-pod sidecar (resource overhead, lifecycle coupling,
injection races). **Istio ambient mode** removes that: encryption moves into a per-node ztunnel,
so meshed workloads get mTLS with no sidecar and no manifest change.

## Decision

Run **Istio in ambient mode** as the service mesh, and keep **Cilium's own encryption/mesh
features disabled**. Encryption-in-transit and workload identity are Istio's responsibility; the
datapath and network policy are Cilium's.

Concrete shape:

- **Istio `v1.31.3`, `profile: ambient`**, four releases in `istio-system` from
  `oci://ghcr.io/istio/release/charts/*`: `base` (CRDs), `istiod`, `cni`, and `ztunnel`.
- **Ambient data plane:** pod traffic in meshed namespaces is redirected by `istio-cni` to the
  per-node **ztunnel**, which carries it over mutual-TLS **HBONE** tunnels (TCP `15008`) between
  nodes. No sidecars.
- **STRICT mTLS mesh-wide.** A `default` `PeerAuthentication` in the `istio-system` root
  namespace sets `mtls.mode: STRICT`, so plaintext peers are rejected, not merely tolerated.
- **Opt-in by namespace label** `istio.io/dataplane-mode: ambient` on each participating
  namespace (alloy, cnpg-system, envoy-gateway, gateways, home, media, network, resume,
  vaultwarden, volsync-system, external-secrets, download, dev, kopiur-system).
- **Cilium encryption stays off.** No WireGuard/IPsec is configured; Cilium carries plaintext
  on the native-routed fabric and Istio HBONE provides the mTLS. Cilium is told to coexist with
  the Istio CNI: `cni.exclusive: false` and `socketLB.hostNamespaceOnly: true`.
- **No mesh-wide `AuthorizationPolicy` (yet).** The current posture is identity + encryption
  (STRICT mTLS), not L4 identity authorization. A mesh-wide deny-by-default authorization layer
  is a possible future step; today, reachability is governed by Cilium network policy (the
  per-namespace + clusterwide CNP audit project) and confidentiality/identity by the mesh.

### The istio-cni node-IP patch (the non-obvious part)

Ambient mode health-probes meshed pods from a **node-local source address**, which upstream
defaults to a link-local address. Under Cilium **native routing**, the
link-local range is **not routable across nodes**, so a health probe (or any
ztunnel-originated traffic) that must cross from one node to a pod on another node is dropped.

The fix is a post-render patch on the `istio-cni` DaemonSet
(`kubernetes/apps/istio-system/istio/cni/helmrelease.yaml`) that sets the probe SNAT source to
the **node IP** instead of the link-local address:

```yaml
spec:
  postRenderers:
    - kustomize:
        patches:
          - target: { kind: DaemonSet }
            patch: |
              # ...
              env:
                - name: HOST_PROBE_SNAT_IP
                  valueFrom:
                    fieldRef:
                      fieldPath: status.hostIP
```

`HOST_PROBE_SNAT_IP = status.hostIP` makes ambient health/probe traffic source from the
routable node address, so it survives native routing and cross-node delivery. The clusterwide
`allow-ambient` policy still admits that link-local address for the in-node
(pod↔ztunnel) leg before SNAT, alongside the HBONE `15008` ingress/egress allow.

## Rationale

- **Mesh cost should scale with nodes, not pods.** Ambient collapses N per-pod Envoy sidecars into
  one ztunnel per node, so the mesh's footprint decouples from pod count, dense nodes benefit most.
  Sidecars also tax every pod's startup (an init-container iptables rewrite plus a sidecar-ready
  gate) and couple the mesh's lifecycle to the workload's: an L4/mesh upgrade would mean restarting
  every meshed pod.
- **Workload-identity mTLS is a stronger property than datapath encryption.** Cilium WireGuard/IPsec
  secures node-to-node bytes but gives no per-service SPIFFE identity, no STRICT "plaintext-rejected"
  peer authentication, and no identity-based authorization substrate. The mesh provides all three,
  independently of the CNI, keeping Cilium a pure L3/L4 datapath + policy engine and Istio the
  identity/encryption layer.
- **STRICT, not permissive.** STRICT PeerAuthentication rejects plaintext rather than tolerating it,
  so an unmeshed or spoofed peer cannot talk to a meshed service. Identity and mTLS are enforced at
  the node ztunnel rather than a per-pod proxy, and would be identical if a namespace later moved to
  sidecars.
- **L7 is pay-for-what-you-use.** Ambient gives L4 mTLS to everything; richer L7 features (HTTP
  routing, per-route authorization) are added per namespace via a waypoint only where needed, rather
  than spawning an Envoy in every pod by default.

## Consequences

- Transparent, sidecar-free mTLS on all meshed service traffic, with SPIFFE workload identity
  and STRICT (plaintext-rejected) peer authentication, no per-app changes.
- Clean separation of concerns: Cilium = datapath + L3/L4 policy; Istio = identity + in-transit
  encryption. Each can be reasoned about and upgraded independently.
- Lower overhead than sidecar mesh; no injection races in pod lifecycle.
- Native routing keeps the datapath simple and fast; encryption rides HBONE only where meshed.
- The node-IP patch is a **non-obvious, version-sensitive** workaround. An Istio chart bump
  could rename or restructure the DaemonSet env/args and silently break cross-node ambient
  health, the patch must be re-verified on every istio upgrade.
- Two systems now touch the datapath (Cilium CNI + Istio CNI). `cni.exclusive: false` and
  `socketLB.hostNamespaceOnly: true` are required and easy to forget; getting them wrong breaks
  pod networking.
- Ambient is newer than sidecar mode; the operational knowledge base and some corner-case
  behaviors are less battle-tested.
- Encryption is only present for **meshed** namespaces. Non-meshed traffic is plaintext on the
  native fabric; confidentiality there relies on the trusted L2 and Cilium policy, not crypto.
- Because Cilium encryption is off, adding WireGuard later (e.g. for non-meshed traffic) remains
  an open option without conflicting with the mesh.

## Alternatives considered

- **Cilium WireGuard/IPsec transparent encryption (no mesh):** encrypts the node datapath with
  less moving machinery, but provides no workload-identity mTLS, no STRICT peer authentication,
  and no identity-based authorization substrate, a weaker security property than the mesh, and
  not aligned with a zero-trust east-west goal.
- **Istio in sidecar mode:** mature and well-understood, but reintroduces per-pod proxy
  overhead, injection races, and lifecycle coupling that ambient specifically removes.
- **Linkerd / Cilium Service Mesh (Envoy-based L7):** viable meshes, but Istio ambient is the
  direction with the strongest momentum for sidecar-free mTLS and integrates with the Gateway
  API ingress path already in use (see [ADR 0006](0006-gateway-api-ingress-with-coraza-waf.md)).
