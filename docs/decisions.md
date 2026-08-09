# Design decisions

Each decision records what was chosen, what was rejected, and the evidence. Where a
measurement drove the choice, the measurement is reproduced so it can be re-checked when
hardware changes.

---

## 1. External Postgres datastore instead of embedded etcd

**Decision:** all three nodes are k3s servers pointing at an external Neon Postgres via
`--datastore-endpoint`, using kine.

**Rejected:** 3-member embedded etcd (`--cluster-init`), the conventional k3s HA answer.

**Evidence.** etcd requires 99th-percentile fsync latency under **10 ms**. Measured with
etcd's own recommended fio invocation:

```bash
fio --rw=write --ioengine=sync --fdatasync=1 --directory=$DIR --size=22m --bs=2300 --name=etcdtest
```

| node | media | fsync p99 | p99.9 | verdict |
|---|---|---|---|---|
| ashx1 | SD card | 8.2 ms | 15.8 ms | marginal |
| ashx2 | Oracle block volume | **2.3 ms** | 3.9 ms | fine |
| ashx3 | SD card | **11.5 ms** | **40.6 ms** | fails |

ashx3 fails outright and ashx1 is borderline. Beyond latency, etcd's continuous fsync
traffic destroys SD cards.

**The failure-domain argument mattered as much as the latency.** A 3-member etcd would
have placed 2 of 3 voters at home. That survives an Oracle outage but *not* a home
outage — the cloud node alone would lose quorum and go read-only. The external datastore
survives either direction.

**Accepted cost:** Neon becomes a hard dependency for the whole control plane, and it is
on a free tier. See risk 1 below.

**Revisit when:** ashx1 and ashx3 boot from USB3 SSDs. Then embedded etcd becomes viable
and removes the external dependency entirely.

---

## 2. `--flannel-iface=tailscale0` instead of k3s `--vpn-auth`

**Decision:** standard flannel VXLAN encapsulated inside the existing tailnet.

**Rejected:** k3s's built-in Tailscale integration
(`--vpn-auth="name=tailscale,joinKey=..."`), which is what the k3s docs describe.

**Why.** `--vpn-auth` makes k3s manage `tailscaled` itself and advertise the pod CIDR
(`10.42.0.0/16`) as a tailnet route. That requires editing the tailnet policy file to add
`autoApprovers` for the route, plus an ACL accept rule, plus an auth key. All three nodes
already ran `tailscaled` independently, so this added admin-console coupling for no
functional gain.

`--flannel-iface` gets identical pod reachability with zero tailnet policy changes.

**Verified:** each node's `flannel.alpha.coreos.com/public-ip` annotation is its `100.x`
Tailscale address, confirming encapsulation rides the tailnet rather than the LAN.

---

## 3. All three nodes are control-plane

**Decision:** no dedicated agents.

**Why.** With an external datastore there is no quorum to protect, so additional API
servers are close to free — each one is another endpoint that can serve `kubectl` and
another candidate for controller-manager leader election. With only three machines,
dedicating any of them to agent-only duty would reduce availability for no benefit.

Note this differs from the etcd case, where an even number of members or too many voters
is actively harmful.

---

## 4. Which node was the first server

**Decision (superseded, recorded for context):** the original single-server build put the
control plane on **ashx2** (Oracle), not on the faster, better-connected ashx1.

**Why.** Control-plane availability dominates latency. 21 ms between kubelet and API
server is well within tolerance; a home power cut is not. With ashx2 as server, a home
outage leaves a working control plane on a node that is still up. With ashx1 as server,
the same outage takes out the control plane *and* two of three nodes.

Superseded by decision 3 — all nodes are now servers — but the reasoning still governs
which node to treat as primary when one must be chosen (e.g. `--server` bootstrap target,
default kubeconfig context).

---

## 5. Neon connection string: direct endpoint, no channel binding

**Decision:** use Neon's **direct** endpoint and `sslmode=require` only.

Two modifications to the connection string Neon hands you:

- **Dropped `-pooler`.** kine holds long-lived connections and uses prepared statements.
  PgBouncer transaction pooling adds a failure mode for only three clients, and at 4 ms
  from ashx2 it buys nothing.
- **Dropped `channel_binding=require`.** kine uses Go's `lib/pq`, which does not
  recognise that parameter and fails to connect. TLS is still enforced by `sslmode`.

---

## 6. Datastore credentials in `config.yaml`, not the systemd unit

**Decision:** all k3s flags live in `/etc/rancher/k3s/config.yaml`, mode **0600**,
root-owned.

**Why.** Passing `--datastore-endpoint` via `INSTALL_K3S_EXEC` bakes it into the systemd
unit's `ExecStart`, making the Postgres password visible to any local user through
`ps aux` or `systemctl cat`. A 0600 config file keeps it readable only by root.

---

## 7. Tailscale operator needs OAuth, not an auth key

**Decision:** OAuth client, with credentials supplied as a pre-created `operator-oauth`
Secret rather than Helm values.

**Why an auth key cannot work.** The operator mints a *new* auth key for every proxy
device it creates — that is what the `Keys → Auth Keys: Write` scope is for. A static
auth key authenticates one device and cannot issue keys for others. This is structural.
Inspecting the chart confirms it: `helm show values tailscale/tailscale-operator` exposes
only `oauth.clientId`/`oauth.clientSecret`, `oauth.audience` (workload identity
federation) and `oauthSecretVolume`. There is no `authKey` field.

The `TS_AUTHKEY` setup in Tailscale's Kubernetes docs belongs to the sidecar / proxy /
subnet-router patterns — static single-device deployments where one key for one device
is sufficient.

**Why a pre-created Secret.** The chart accepts an existing `operator-oauth` Secret. This
keeps the client secret out of Helm values, shell history and any CI log.

---

## Known risks

**1. Neon free-tier compute budget.** A k3s control plane writes continuously, so the
Neon compute never autosuspends — roughly 730 hours/month of activity against a free-plan
budget of ~192 CU-hours. At the 0.25 CU minimum this lands right at the edge; any
autoscaling above that exceeds it. **If the quota is exhausted, all three control planes
stop**, because the datastore is a shared hard dependency. Watch the Neon usage dashboard.

**2. ashx1 kernel netfilter gap.** The Radxa vendor kernel omits
`CONFIG_NETFILTER_XT_MATCH_STATISTIC`, without which kube-proxy programs *zero* service
rules. Worked around with an out-of-tree module that must be rebuilt after every kernel
upgrade. See `docs/troubleshooting.md`.

**3. Oracle Always Free reclamation.** ashx2 is a `VM.Standard.A1.Flex` at 4 OCPU / 24 GB,
exactly the Always Free Ampere allocation. Oracle reclaims idle Always Free compute.
Running the control plane raises its baseline utilisation, which helps.

**4. ashx1 runs Debian 11, which is EOL.** Upgrade path researched — see
`docs/runbook.md`. It is not an in-place upgrade.
