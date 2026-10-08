# Troubleshooting

Real failures encountered in this cluster, with the diagnostic path that found them.
These are documented because every one of them is likely to recur after an OS or
firmware update.

---

## Golden rule: verify both network layers separately

Pod-to-pod (flannel) and ClusterIP (kube-proxy) are independent. A node can pass a full
pod-to-pod mesh while every service and DNS lookup on it is dead.

This actually happened: after the Postgres rebuild the pod-to-pod mesh passed 9/9 while
ashx1 had **zero** service rules. The mesh test alone gave false confidence.

```bash
# Layer 1 — pod to pod (flannel)
kubectl exec POD_A -- wget -qO- http://POD_B_IP/

# Layer 2 — DNS and ClusterIP (kube-proxy)  <-- do not skip
kubectl exec POD_A -- nslookup kubernetes.default.svc.cluster.local
kubectl exec POD_A -- wget -qO- http://SOME_SERVICE.default.svc.cluster.local/

# Fastest single indicator, per node — all nodes should be non-zero and similar
for n in ashx1 ashx2 ashx3; do
  echo -n "$n: "; ssh $n 'sudo iptables-save -t nat | grep -c KUBE-SVC'
done
```

---

## ashx1: no ClusterIP or DNS, pod-to-pod fine

**Symptom.** Pods on ashx1 time out resolving `kubernetes.default.svc`. Pod-to-pod works.
`iptables-save -t nat | grep -c KUBE-SVC` returns **0** on ashx1, 32 on the others.

**Cause.**

```
iptables-restore: Couldn't load match `statistic': No such file or directory
```

kube-proxy uses the `statistic` match to spread traffic across endpoints. The Radxa
vendor kernel is built with `# CONFIG_NETFILTER_XT_MATCH_STATISTIC is not set`. Because
`iptables-restore` is a single transaction, the *entire* ruleset fails to apply — hence
zero rules rather than partial ones.

**Why no other kube-proxy mode helps on this kernel:**

| mode | blocker |
|---|---|
| iptables | `xt_statistic` not compiled — kernel option, no package can supply it |
| ipvs | needs `ipset`; the ipset kernel module directory is absent entirely |
| nftables | needs `nft` ≥ 1.0.1; Debian 11 ships 0.9.8, and it is not in bullseye-backports |

**Fix in place: out-of-tree module.** The headers package for the exact running kernel is
installed, module signing is not enforced and `MODVERSIONS` is off, so the single missing
module can be compiled:

```bash
/opt/xt_statistic/rebuild.sh && sudo systemctl restart k3s
```

Source and script live in `/opt/xt_statistic/` on ashx1. Verify:

```bash
lsmod | grep xt_statistic
sudo iptables-save -t nat | grep -c KUBE-SVC     # expect ~32, not 0
```

> **This must be re-run after every kernel upgrade on ashx1.** A kernel upgrade creates a
> new `/lib/modules/<version>/` and the module silently disappears, taking all service
> networking on that node with it.

**Why not DKMS.** DKMS would automate the rebuild, but it fails here: the Radxa headers
package omits `include/generated/autoconf.h`, and DKMS's `KERNELRELEASE=` invocation
triggers a kernel config regeneration that then errors. A manual `make` avoids that code
path. Fixing it means mutating the shared headers tree that three other DKMS modules
(`aic8800-usb`, `img-bxm-dkms`, `radxa-overlays`) build against, so it was deliberately
left alone.

**Note the Debian 13 upgrade does not fix this.** The 6.6 vendor kernel has the same
`CONFIG_NETFILTER_XT_MATCH_STATISTIC` and `CONFIG_IP_SET` omissions. It fixes the problem
a *different* way — trixie ships nftables 1.1.3, making `--proxy-mode=nftables` viable.

---

## ashx2: tailscaled health error, `xt_mark` missing

**Symptom.** `tailscale status` reports a health error:

```
adding [-i tailscale0 -j MARK --set-mark ...]: Extension MARK revision 0 not supported,
missing kernel module?
```

**Cause.** Not a missing package. The node was booted on kernel `211.7.3` while the
installed `kernel-modules-extra` packages were for `211.38.1` and `211.40.1`. Kernel
modules must match the *running* kernel exactly.

**Fix.** Reboot into the newest installed kernel (already the default GRUB entry), or
install `kernel-modules-extra-$(uname -r)`.

```bash
uname -r
rpm -q kernel-modules-extra-$(uname -r)     # must match
lsmod | grep xt_mark
```

---

## ashx3: kubelet will not start, memory cgroup missing

**Symptom.** `/sys/fs/cgroup/cgroup.controllers` lacks `memory`.

**Cause.** Raspberry Pi firmware injects `cgroup_disable=memory` into the kernel command
line. It is *not* in `cmdline.txt` — the firmware adds it.

**Fix.** Firmware arguments come first and `cmdline.txt` contents are appended, so
appending wins:

```bash
# add to the single line in /boot/firmware/cmdline.txt, then reboot
cgroup_enable=memory cgroup_memory=1
```

Verify: `cat /sys/fs/cgroup/cgroup.controllers` must include `memory`.

A firmware or OS update can revert this.

---

## ashx2: dnf fails, breaking the k3s installer

**Symptom.** `repomd.xml GPG signature verification error: Signing key not found` for the
`tailscale-stable` repo. Any `dnf install` fails — including the k3s installer's
`k3s-selinux` step, which is required on SELinux-enforcing hosts.

**Fix.**

```bash
sudo rpm --import https://pkgs.tailscale.com/stable/fedora/repo.gpg
sudo dnf -q repolist        # all repos should list cleanly
```

---

## ashx4: node goes NotReady 15 minutes after boot

**Symptom.** Node joins, goes `Ready`, then `NodeStatusUnknown`. SSH and ARP dead on the
LAN too, so it looks like a crash. No panic in the logs.

**Cause.** Ubuntu's desktop image runs GDM. Its greeter's `gsd-power` suspends the machine
after 900 s idle at the login screen. The previous boot's kernel log ends in
`PM: suspend entry (s2idle)`.

**Fix.** The `common` role masks `sleep`, `suspend`, `hibernate` and `hybrid-sleep`
targets on every node. Verify: `systemctl is-enabled suspend.target` prints `masked`.

---

## Tailscale operator pod runs but does nothing

**Symptom.** Operator pod `Running`, no device appears in the tailnet, logs empty or
showing DNS timeouts to `10.43.0.10`.

**Cause.** Almost certainly *not* the operator. It was scheduled onto a node with broken
service networking (see ashx1 above). The operator needs cluster DNS to reach the API.

**Diagnosis.** Check which node it landed on, then check that node's service rules. To
read logs when the API path is unreliable, go straight to the container runtime on the
node:

```bash
kubectl get pods -n tailscale -o wide
ssh <node> 'sudo /usr/local/bin/k3s crictl logs --tail 30 $(sudo /usr/local/bin/k3s crictl ps -q --name operator)'
```

**Also expected:** the API server proxy returns `Forbidden` until the tailnet identity has
an RBAC binding. That error means auth *worked*.

---

## Diagnostic patterns worth internalising

**Uniform failure across all nodes usually means a broken test, not a broken cluster.**
Twice during this build a test reported total failure and was wrong:

- A mesh test reported 0/9 including *pod-to-itself*. Cause: `grep -c "Welcome to nginx"`
  returns **2** (the string appears in both `<title>` and `<h1>`), and the assertion
  checked `= 1`.
- `kubernetes.default=FAIL` on all three nodes. Cause: an unauthenticated request
  correctly returning `401`. With the service account token it returned the version JSON.

If something fails everywhere *including* the trivial self-referential case, suspect the
harness first.

**Empty logs may just be timing.** A pod that started 20 s ago may not have logged yet.
Check the container start time before concluding log retrieval is broken.

**Read the config, not the module.** For "is this kernel feature available", the
authoritative check is the build config, not whether a module loads:

```bash
zgrep CONFIG_FOO /proc/config.gz || grep CONFIG_FOO /boot/config-$(uname -r)
```
