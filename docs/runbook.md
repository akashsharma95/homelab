# Runbook

Operational procedures.

**Status:** rebuilt on embedded etcd on 2026-10-08 and converged — a second run reports
`changed=0` everywhere. Validated with `ansible-lint` at the production profile,
`--syntax-check`, and a post-apply functional test (9/9 pod-to-pod mesh, plus DNS and
ClusterIP from every node, 3 voting etcd members, API access over the tailnet).

---

## Add a new node

The whole point of the Ansible layer. A new node becomes a full control-plane member.

**1. Prepare the machine**
- Install a 64-bit OS and get it on the tailnet (`tailscale up`).
- Note its `100.x` address: `tailscale ip -4`.
- Ensure you can SSH in as some account with sudo.

**2. Add it to `ansible/inventory.yml`**

```yaml
k3s_servers:
  hosts:
    newnode:
      node_ip: 100.x.y.z

# plus its hardware class, which selects the prerequisite role
debian_family:
  hosts:
    newnode:
```

`k3s_tls_sans` derives from inventory, so there is nothing else to edit — but the other
servers only pick up the new SAN on their next converge.

Every server is also an etcd member, so keep the server count odd — see
`docs/decisions.md` #3.

**3. Converge**

```bash
export K3S_TOKEN='...'
cd ansible

# dry run first
ansible-playbook -i inventory.yml site.yml --limit newnode --check --diff

ansible-playbook -i inventory.yml site.yml --limit newnode
```

On the very first run the operator account does not exist yet, so connect as the vendor
account: `--limit newnode -u pi -k`. Subsequent runs use `ash`.

A Raspberry Pi needs a reboot for the memory cgroup. The play fails with an explicit
message rather than continuing into a confusing kubelet failure; pass `-e allow_reboot=true`
to let it reboot and wait, or reboot yourself and re-run.

**4. Verify — Ready is not enough**

```bash
kubectl get nodes -o wide
ssh newnode 'sudo iptables-save -t nat | grep -c KUBE-SVC'   # must be non-zero
```

Then run the full two-layer check in `docs/troubleshooting.md`. A node can be `Ready`
with completely broken service networking.

---

## Verify cluster health

```bash
kubectl get nodes -o wide

# Service rules on every node — the check that catches silent kube-proxy failure
for n in ashx1 ashx2 ashx3; do
  echo -n "$n: "; ssh $n 'sudo iptables-save -t nat | grep -c KUBE-SVC'
done

# Flannel must be riding the tailnet, not the LAN: expect 100.x addresses
kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'

# etcd: every node lists the etcd role, and the API server sees etcd as healthy
kubectl get nodes          # ROLES: control-plane,etcd on all three
ssh ashx2 'sudo k3s kubectl get --raw "/readyz?verbose"' | grep etcd
```

Full functional test — deploy a DaemonSet and exercise both network layers. See
`docs/troubleshooting.md` for the exact commands.

---

## After a kernel upgrade on ashx1

**Required, or all service networking on that node breaks silently.**

```bash
ssh ashx1 'sudo /opt/xt_statistic/rebuild.sh && sudo systemctl restart k3s'
ssh ashx1 'sudo iptables-save -t nat | grep -c KUBE-SVC'    # expect ~32
```

Or equivalently, since the role is keyed on the kernel version:

```bash
ansible-playbook -i inventory.yml site.yml --limit ashx1
```

Background in `docs/troubleshooting.md`.

---

## etcd snapshots and restore

k3s snapshots etcd at 00:00 and 12:00 and keeps 5 per server, on local disk
(`/var/lib/rancher/k3s/server/db/snapshots`). Off-node copies are not configured.

```bash
ssh ashx2 'sudo k3s etcd-snapshot ls'
ssh ashx2 'sudo k3s etcd-snapshot save'      # on demand, e.g. before an upgrade
```

Restore (from the [k3s docs](https://docs.k3s.io/cli/etcd-snapshot)) — the whole cluster
goes back to the snapshot:

```bash
for n in ashx1 ashx2 ashx3; do ssh $n 'sudo systemctl stop k3s'; done
ssh ashx2 'sudo k3s server --cluster-reset --cluster-reset-restore-path=<SNAPSHOT>'
ssh ashx2 'sudo systemctl start k3s'
for n in ashx1 ashx3; do ssh $n 'sudo rm -rf /var/lib/rancher/k3s/server/db && sudo systemctl start k3s'; done
```

**Quorum lost and not coming back** (e.g. home is down for good): `--cluster-reset`
*without* a restore path resets ashx2 to a single-member cluster with its current data.
Start it normally afterwards, then rejoin the others as above.

---

## Replace a failed server

The etcd member must be removed or new servers may fail to join. One node at a time, so
the rest keep quorum (k3s
[v1.22.7 release notes](https://github.com/k3s-io/k3s/releases/tag/v1.22.7%2Bk3s1)):

```bash
ssh <node> 'sudo systemctl stop k3s'       # if it still runs; otherwise it rejoins
kubectl delete node <node>                 # k3s removes its etcd member
ssh <node> 'sudo /usr/local/bin/k3s-uninstall.sh'
ansible-playbook -i inventory.yml site.yml --limit <node>
```

Replacing **ashx2** itself: it is the first inventory host, so its config says
`cluster-init`, and a fresh ashx2 would start a new, separate cluster. Move another server
to the top of `k3s_servers` first, so ashx2 joins it instead.

---

## Rotate the cluster token

```bash
ssh ashx2 'sudo k3s token rotate'
# then update K3S_TOKEN and converge
ansible-playbook -i inventory.yml site.yml
```

---

## Upgrade Kubernetes

Bump `k3s_version` in `group_vars/all.yml`, then converge. The installed version is
compared against it, so the installer re-runs only where they differ. `serial: 1` means
one node upgrades at a time and the other two keep serving the API.

```bash
ansible-playbook -i inventory.yml site.yml
kubectl get nodes    # confirm versions before moving on
```

---

## Debian 13 upgrade for ashx1 (researched, not yet performed)

ashx1 runs Debian 11, which is EOL. Findings as of 2026-08-09:

**Images exist and the trixie track is better maintained than bullseye.**
`radxa-a733_trixie_cli_t5` (2026-08-04) with kernel 6.6.98-4-aw2511. The bullseye line
stopped at r6 in April; trixie went t3 (May) → t4 (Jun) → t5 (Aug).

**It cannot be done in place.** There is no `a733-bookworm` repo at all — Radxa skipped
bookworm for this SoC — and Debian does not support skipping releases. The only path is
reflashing the SD card.

**It does not fix `xt_statistic`.** The 6.6 kernel has the same
`CONFIG_NETFILTER_XT_MATCH_STATISTIC` and `CONFIG_IP_SET` omissions. It fixes the problem
differently: trixie ships nftables 1.1.3 and the kernel has `NFT_NUMGEN`/`NFT_CT`/
`NFT_NAT`/`NFT_MASQ`, so `--proxy-mode=nftables` becomes viable — no out-of-tree module,
no ipset.

**Caveats.** Only `a733-trixie-test` exists; there is no stable `a733-trixie`, unlike
other Radxa SoCs. Tempering that, *all* A733 images are tagged prerelease including the
bullseye one currently running, so prerelease is normal for this SoC. The image is
SoC-generic (`radxa-a733`), not board-specific, but the current install came off the same
generic line and `task-radxa-cubie-a7s` exists in the trixie repo.

**Procedure (when you do it):**

1. Flash **a new SD card** — keep the current one untouched as instant rollback.
2. Boot, `tailscale up`, confirm the same `100.86.153.102` is issued (or update inventory).
3. Add `kube-proxy-arg: ["proxy-mode=nftables"]` to the k3s config for this host, and drop
   it from the `radxa_a733` group so the module build is skipped.
4. `ansible-playbook -i inventory.yml site.yml --limit ashx1 -u radxa -k`
5. Verify service rules — with nftables mode, check `nft list ruleset | grep -c kube` rather
   than `iptables-save`.

If the board misbehaves, swap the old card back. A fresh card is a new etcd member, so
follow "Replace a failed server" — it does not simply rejoin.

---

## Emergency: cluster unreachable

**Symptom: `kubectl` fails everywhere.**
Likely lost etcd quorum: two of three servers are down or cannot reach each other. A home
outage does exactly this. Check which servers are up and can reach each other over the
tailnet:

```bash
for n in ashx1 ashx2 ashx3; do ssh $n 'systemctl is-active k3s; tailscale status | head -4'; done
ssh ashx2 'sudo journalctl -u k3s -n 50 | grep -i etcd'
```

Bringing the second member back restores quorum. If it cannot come back, see "etcd
snapshots and restore".

Running workloads keep serving traffic while the control plane is down. You lose the
ability to schedule or change things, not the things already running.

**Symptom: the tailnet kubectl context fails.**
The operator runs inside the cluster and cannot help when the cluster is unhealthy. Fall
back to a direct context:

```bash
kubectl --context=ashx2 get nodes
```

**Symptom: one node is bad and you want it out of the way.**

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... fix ...
kubectl uncordon <node>
```

---

## Teardown

```bash
ssh <node> 'sudo /usr/local/bin/k3s-uninstall.sh'          # server
ssh <node> 'sudo /usr/local/bin/k3s-agent-uninstall.sh'    # agent, if any
```

Uninstall deletes `/var/lib/rancher/k3s`, including etcd data and local snapshots. Copy
a snapshot off the node first if you want to keep the cluster state.

---

## Tags

```bash
ansible-playbook -i inventory.yml site.yml --tags common       # user + sudo
ansible-playbook -i inventory.yml site.yml --tags prereqs      # hardware/OS prerequisites
ansible-playbook -i inventory.yml site.yml --tags xt_statistic # ashx1 kernel module only
ansible-playbook -i inventory.yml site.yml --tags k3s          # config + service
ansible-playbook -i inventory.yml site.yml --tags operator     # Tailscale operator
```
