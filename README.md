# homelab

A four-node Kubernetes (k3s) cluster — three servers and one agent — stretched across a home lab and Oracle Cloud,
joined over a Tailscale tailnet, with embedded etcd as the control-plane datastore.

This repo is both the **documentation** of that cluster and the **automation** to rebuild
it or add a node to it.

---

## Contents

| Path | What it is |
|---|---|
| `README.md` | This file — architecture, topology, design rationale |
| `docs/decisions.md` | Why each significant choice was made, with the evidence |
| `docs/runbook.md` | Operational procedures — add a node, rotate secrets, kernel upgrades |
| `docs/troubleshooting.md` | Real failures hit in this cluster and how they were diagnosed |
| `ansible/` | Node provisioning (the actual automation) |
| `terraform/` | Tailscale tailnet policy |

---

## Architecture at a glance

```
        ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
        │     ashx1      │ │     ashx2      │ │     ashx3      │
        │  Radxa Cubie   │ │  Oracle Cloud  │ │ Raspberry Pi 4 │
        │     A7S        │ │   Ampere A1    │ │                │
        │ control-plane  │ │ control-plane  │ │ control-plane  │
        │ + etcd member  │ │ + etcd (init)  │ │ + etcd member  │
        │ 100.86.153.102 │ │ 100.108.19.113 │ │  100.97.6.117  │
        └────────┬───────┘ └────────┬───────┘ └────────┬───────┘
                 │                  │                  │
                 └──────────────────┼──────────────────┘
                                    │
                           ┌────────┴───────┐
                           │     ashx4      │
                           │ Radxa Dragon   │
                           │      Q6A       │
                           │  agent only    │
                           │ 100.76.119.113 │
                           └────────────────┘
                    flannel VXLAN + etcd peers over tailscale0
                    pods 10.42.0.0/16 · svc 10.43.0.0/16
```

**ashx1–3 are control-plane nodes.** Each runs an API server, scheduler,
controller-manager and an etcd member, and also runs workloads. **ashx4 is an agent**:
workloads only, no etcd member, so it does not change quorum. See `docs/decisions.md` #3.

### Node inventory

| | ashx1 | ashx2 | ashx3 | ashx4 |
|---|---|---|---|---|
| Hardware | Radxa Cubie A7S | Oracle Ampere A1.Flex | Raspberry Pi 4B | Radxa Dragon Q6A |
| SoC / arch | Allwinner A733, arm64 | Ampere, arm64 | BCM2711, arm64 | Qualcomm QCM6490, arm64 |
| OS | Debian 11 (bullseye) | AlmaLinux 10.2 | Debian 13 (trixie) | Ubuntu 24.04 |
| Kernel | 5.15.147-21-a733 (vendor) | 6.12.0-211.61.1.el10_2 | 6.18.50+rpt-rpi-v8 | 6.18.2-3-qcom (vendor) |
| CPU / RAM | 8 cores / 8 GB | 4 OCPU / 24 GB | 4 cores / 8 GB | 8 cores / 12 GB |
| Storage | 238 GB SD card | 46 GB boot + 147 GB volume | 58 GB SD card | 512 GB NVMe |
| Role | server | server (etcd init) | server | agent |
| Tailnet IP | 100.86.153.102 | 100.108.19.113 | 100.97.6.117 | 100.76.119.113 |
| Location | Home (UK) | uk-london-1 | Home (UK) | Home (UK) |
| Login | `ash` (orig. `radxa`) | `ash` (orig. `opc`) | `ash` | `ash` (orig. `radxa`) |

Latency: ashx1↔ashx3 ~1.5 ms (same LAN), home↔ashx2 ~21 ms.

### Software

| Component | Version / choice |
|---|---|
| Kubernetes | k3s v1.37.1+k3s1 |
| Datastore | embedded etcd, 3 members |
| CNI | flannel, VXLAN backend, bound to `tailscale0` |
| Ingress | Traefik (k3s default) |
| Storage | local-path provisioner |
| Overlay network | Tailscale 1.104.1 (node-level) |
| Tailnet integration | Tailscale Kubernetes operator 1.102.4 |

---

## How the pieces fit

### Networking: two independent layers

This distinction matters and has bitten us (see `docs/troubleshooting.md`):

1. **Pod-to-pod** is flannel VXLAN, encapsulated inside the tailnet via
   `--flannel-iface=tailscale0`. Each node's flannel `public-ip` annotation is its
   `100.x` Tailscale address, so all inter-pod traffic rides the WireGuard mesh.
2. **Service (ClusterIP) traffic** is kube-proxy, programming iptables/nftables rules on
   each node independently of flannel.

**A node can pass every pod-to-pod test while all ClusterIP and DNS traffic on it is
completely broken.** Always verify both layers separately.

We deliberately do *not* use k3s's `--vpn-auth` Tailscale integration. That mode makes
k3s manage `tailscaled` and advertise the pod CIDR as a tailnet route, which requires
`autoApprovers` route approval and ACL edits in the Tailscale admin console.
`--flannel-iface` achieves the same reachability with no tailnet policy changes.

### Control plane: embedded etcd

Each server runs an etcd member. ashx2 initialises the cluster (`cluster-init`); ashx1
and ashx3 join it. Until 2026-10 the datastore was an external Neon Postgres via kine;
it was replaced after Neon's free-tier transfer quota cut off all new connections. See
`docs/decisions.md` #8.

Consequences you must understand:

- **Quorum is 2 of 3.** Any one node can fail and the cluster keeps working.
- **Two of the three members are at home.** A home outage leaves ashx2 alone, without
  quorum: the API stops everywhere. An Oracle outage is survivable. The old external
  datastore survived both; this is the accepted cost of dropping it.
- **etcd fsyncs continuously to SD cards** on ashx1 and ashx3. That is slow (ashx3 failed
  etcd's fsync benchmark) and wears the cards. See `docs/decisions.md` known risks.
- Running workloads keep serving traffic without quorum; you just cannot schedule or
  change anything.

### Tailnet integration

Two independent things both use Tailscale, and they are easy to conflate:

- **Node-level `tailscaled`** on each host provides the `100.x` addresses that flannel and
  the API servers talk over. This is what makes the cluster possible.
- **The Tailscale Kubernetes operator** runs *inside* the cluster and exposes cluster
  resources onto the tailnet. It publishes the Kubernetes API as a single tailnet device
  (`tailscale-operator.<tailnet>.ts.net`), giving one stable `kubectl` endpoint instead of
  per-node addresses.

The operator requires an **OAuth client**, not an auth key. It mints a fresh auth key for
every proxy device it creates, which needs the `Keys → Auth Keys: Write` scope; a static
auth key can authenticate one device but cannot issue keys for others. Auth keys *do* work
for the simpler sidecar / subnet-router patterns, which is a different deployment model.

Because the operator lives inside the cluster, it cannot help you reach a cluster whose
control plane is already down. Keep the direct per-node kubeconfig contexts as a fallback.

---

## Access

```bash
# Via the tailnet (stable, survives any one node failing)
kubectl --context=tailscale-operator.<your-tailnet>.ts.net get nodes

# Direct to a specific node's API server (fallback)
kubectl --context=ashx1 get nodes
kubectl --context=ashx2 get nodes
kubectl --context=ashx3 get nodes
```

SSH is `ssh ashx1` / `ashx2` / `ashx3` — `~/.ssh/config` maps these to user `ash`, whose
keys come from the Bitwarden SSH agent. Original vendor logins (`radxa@ashx1`,
`opc@ashx2`) are intentionally left intact as a recovery path.

The tailnet API proxy authenticates you as your tailnet identity, which needs an explicit
RBAC binding in the cluster or every request returns `Forbidden`.

---

## Quick start

```bash
# 1. Install tooling
brew install ansible          # required
brew install terraform        # optional, only for the tailnet policy

# 2. Provide secrets (never committed — see ansible/group_vars/all.yml)
export K3S_TOKEN='...'

# 3. Converge the whole cluster (idempotent)
cd ansible && ansible-playbook -i inventory.yml site.yml

# 4. Add a brand-new node
#    add it to inventory.yml, then:
ansible-playbook -i inventory.yml site.yml --limit newnode
```

See `docs/runbook.md` for the full procedure including per-hardware prerequisites.

---

## Repo conventions

- **No secrets in git.** The k3s token and OAuth credentials come from
  environment variables or Ansible Vault. `.gitignore` blocks the usual accidents.
- **Idempotent.** `site.yml` is safe to re-run at any time; it is the mechanism for both
  initial build and ongoing convergence.
- **Per-hardware roles.** The three nodes need genuinely different prerequisites. Rather
  than one playbook full of conditionals, each hardware class gets its own role, selected
  by inventory group.
