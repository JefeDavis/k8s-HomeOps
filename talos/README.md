# Talos (jsdyb-k8s-001)

Multi-document Talos machine config rendered with **minijinja** and
secrets injected from **SOPS** (age + GCP KMS). 3x Intel NUC 11 Pro, all control
plane, Talos v1.14.x / Kubernetes v1.37.x.

## Layout

| File                                | Purpose                                                                                                                                                                                      |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cluster.yaml.j2`                   | Documents applied to every node (network, sysctls, extensions, install disk, kubelet, pod/svc nets).                                                                                         |
| `controlplane.yaml.j2`              | Control-plane-only documents (`machine.type`, CAs, k8s components).                                                                                                                          |
| `nodes/controlplane/<node>.yaml.j2` | Per-node identity (hostname, zone labels).                                                                                                                                                   |
| `schematic.yaml.j2`                 | Image Factory schematic (extensions + kernel args).                                                                                                                                          |
| `talos.sops.yaml`                   | SOPS-encrypted native `talosctl gen secrets` bundle (CAs, tokens, cluster id/secret, etcd encryption) plus a `nut` key for the NUT password. Single source of truth for all cluster secrets. |
| `mise.toml`                         | Render / apply / upgrade / reboot / reset / gen-talosconfig tasks.                                                                                                                           |

Render pipeline: `//:template` (in `.mise/config.toml`) runs
`minijinja-cli <template> <(sops -d talos.sops.yaml) [-D ...]`, then
`render-config` merges cluster + controlplane + node docs with
`talosctl machineconfig patch`. Templates reference the bundle by its native
nested paths (`certs.os.crt`, `secrets.bootstraptoken`, `nut.password`, ...).

## Hardware / network facts

- Single onboard Intel 2.5GbE NIC per node (`igc`), **no bond**. Aliased to `net0`.
- Primary IP via DHCP on the **native/untagged VLAN 77** (reservations map MAC -> .11/.12/.13).
- Tagged **VLAN 90** (`net0.90`) exists with no host IP, as the Multus parent for Home Assistant.
- Control-plane VIP **10.77.0.10** (`Layer2VIPConfig` on `net0`), endpoint
  `jsdyb-k8s-001.internal.davishaus.dev:6443`.
- Install disk: 1TB SATA SSD `CT1000MX500SSD1`. The 2TB NVMe `CT2000P3PSSD8` is
  left **raw** for Rook-Ceph.

## Usage

Requires `mise` tools (`talosctl` 1.14.x, `minijinja-cli`, `sops`, `yq`, `jq`).
If other repo tool pins fail to install (e.g. a delisted `trivy`/`python`
version or a missing `lefthook`), prefix commands with
`MISE_TASK_RUN_AUTO_INSTALL=0` so the broken global tools don't block the task.

```sh
# Generate the talosconfig (client config) from the secret bundle
mise run //talos:gen-talosconfig

# Render a node's merged machine config (stdout)
mise run //talos:render-config jsdyb-nuc-001

# Apply to a node (first apply in maintenance mode: add -- --insecure)
mise run //talos:apply-node jsdyb-nuc-001 -- --insecure

# Bootstrap etcd on the first node, then fetch kubeconfig
talosctl -n 10.77.0.11 bootstrap
talosctl -n 10.77.0.11 kubeconfig talos/clusterconfig

# Upgrade Talos / Kubernetes
mise run //kubernetes/talos:upgrade-node jsdyb-nuc-001
mise run //kubernetes/talos:upgrade-k8s v1.37.x
```

## Secrets

Edit values with `sops talos/talos.sops.yaml`. It is the native bundle produced
by `talosctl gen secrets` (nested `certs` / `secrets` / `cluster` / `trustdinfo`
keys), with one addition: a `nut.password` key for the NUT UPS client. The
`.sops.yaml` rule for `talos/.*\.sops\.yaml` encrypts the whole file (age + GCP
KMS).

The same bundle feeds two consumers:

- **Machine configs** via minijinja (`render-config`), which references the
  nested paths directly.
- **The talosconfig** via `gen-talosconfig`, which runs
  `talosctl gen config --with-secrets` on the bundle with the non-talosctl `nut`
  key stripped (`yq 'del(.nut)'`), so there is a single source of truth and no
  risk of the client cert drifting from the nodes' CA.
