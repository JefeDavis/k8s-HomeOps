# ADR 0001: Talos Linux as the node operating system

## Context

The cluster runs on three Intel NUC 11 Pro mini-PCs on a single flat network. It needs
an operating system that is reproducible, API-driven, minimal in attack surface, and that
treats the node itself as immutable infrastructure rather than a pet to be hand-maintained.

A general-purpose Linux distribution (Ubuntu, Debian, Fedora CoreOS) would mean SSH access,
a package manager, drifting per-node state, and a large surface of installed software that
has nothing to do with running Kubernetes. For a GitOps cluster where _every_ other layer is
declarative and reconciled, a mutable, imperatively-administered host OS is the odd one out
and the most likely source of undocumented drift.

## Decision

Use **Talos Linux** as the node OS on all three nodes.

Concrete shape of the decision:

- **Version floor:** Talos `v1.14.6`, Kubernetes `v1.37.2`, pinned in the machine config
  templates (`talos/cluster.yaml.j2`, `talos/controlplane.yaml.j2`).
- **Topology:** all three nodes are control-plane nodes and are **also schedulable** for
  workloads (Talos 1.14 no longer auto-taints control planes, and no control-plane taint is
  set). This is a homelab, not a large fleet: a dedicated worker tier is not worth the node
  count. A Layer-2 shared VIP fronts the API server, with KubePrism on the loopback (`:7445`)
  for in-node API access.
- **No host CNI, no host kube-proxy, no host CoreDNS.** The machine config disables
  kube-proxy (`cluster.proxy.disabled`) and Talos' built-in CoreDNS, and ships no CNI, so
  Cilium owns the datapath, kube-proxy replacement, and (together with the in-cluster CoreDNS
  release) name resolution. See [ADR 0005](0005-istio-ambient-mesh-over-cilium.md) for the
  networking stack.
- **Image Factory schematic** carries only the extensions this hardware needs:
  `siderolabs/i915` + `intel-ucode` (iGPU transcode), `siderolabs/gvisor` (sandboxed runtime
  class), `siderolabs/thunderbolt` (Thunderbolt NICs), and `siderolabs/nut-client` (UPS
  shutdown). Kernel args enable the iGPU GuC/HuC and VT-d/IOMMU passthrough.
- **Declarative machine config** rendered from `.j2` (minijinja) templates with secrets
  decrypted from a SOPS-encrypted `talosctl` secrets bundle (`talos/talos.sops.yaml`, age +
  GCP KMS). The entire OS configuration lives in git; applying it is `talosctl apply-config`,
  driven by mise tasks.
- **Storage split at the OS layer:** the install disk is the 1 TB SATA SSD; the 2 TB NVMe
  (`CT2000P3PSSD8`) is left **raw and unwiped** so Rook can claim it as a Ceph OSD. The `rbd`
  kernel module is loaded via machine config for the Ceph RBD client.
- **Hardened defaults inherited from Talos:** no shell, no SSH, no package manager; an
  API-only (`talosctl`/gRPC + mTLS) control surface; read-only immutable root; secretbox
  etcd encryption at rest; `defaultRuntimeSeccompProfileEnabled`.

## Rationale

- A GitOps cluster is only as reproducible as its least-declarative layer, and a mutable,
  hand-administered host OS is that layer, the most likely source of undocumented drift. Talos
  makes the node itself declarative and closes the gap.
- Minimal surface is a security property, not just tidiness: with no shell, no SSH, and no package
  manager there is no interactive foothold to harden and no package state to drift.
- API-only management (mTLS gRPC) with image-based A/B upgrades makes node changes atomic and
  reversible, matching how every other layer is operated; a rebuild is re-applying config, not
  re-running a runbook.
- Three schedulable control planes is the right trade at this scale: a dedicated worker tier buys
  an isolation a three-node homelab does not need and would cost a third of the fleet, while etcd
  quorum still tolerates a single node loss.

## Consequences

- The host OS is now as declarative and reproducible as the workloads: a node rebuild is
  re-applying a config, not re-doing a runbook.
- Minimal attack surface and no drift vector. There is no SSH to secure, no apt state to
  reconcile, no one-off manual fix that outlives its author.
- OS and Kubernetes upgrades are atomic, image-based, and rollback-capable (A/B schematic),
  pinned in git.
- Node-level security controls (immutable rootfs, seccomp default, etcd encryption, mTLS API)
  come for free and align with the secure-by-default posture the rest of the platform targets.
- No in-node debugging shell. Troubleshooting is `talosctl`-mediated; operators must learn its
  model rather than reaching for `ssh` + standard tooling.
- Anything the node needs that is not a Talos extension (a kernel module, a sysctl, a mount)
  must be expressed in machine config, which is more constrained than a general distro.
- Running all three nodes as schedulable control planes concentrates etcd and workloads on the
  same hardware; a single node loss removes both a control-plane member and ~1/3 of capacity.
  Acceptable at three nodes with pod topology spread, but it is a real blast-radius trade.
- Config secrets (CAs, bootstrap token, etcd encryption key) live in a SOPS bundle rather than
  in Talos' own secret store, so secret management is unified with the rest of the repo's SOPS
  usage.

## Alternatives considered

- **Generic Linux + kubeadm / k3s:** maximum flexibility and familiar tooling, but reintroduces
  mutable host state, SSH, and a package manager, i.e. exactly the drift and attack surface this
  decision sets out to remove.
- **Flatcar / Fedora CoreOS:** immutable and Ignition-provisioned, closer to the goal, but still
  ship a general-purpose userland and SSH, and lack Talos' API-only control plane and
  Kubernetes-specific minimalism.
