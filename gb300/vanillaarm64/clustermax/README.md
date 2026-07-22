# GB300 on vanilla arm64 — clustermax full-stack (toolkit + GPU-DRA + DCGM + dranet)

The **full-stack** variant. Installs driver (open R580) + **container-toolkit** + **DCGM** +
**dcgm-exporter** from the GPU Operator (**device plugin OFF**), the **NVIDIA GPU DRA driver**
(GPUs as `gpu.nvidia.com` ResourceSlices + ComputeDomains for MNNVL), and **official dranet**
(IB NICs as `dra.net` ResourceSlices). GPUs come from **DRA, not the device plugin**, so a
workload claims a GPU and its aligned IB NIC in one DRA request. Same vanilla arm64 image
(`2404gen2arm64containerd 202606.19.0`), k8s `1.35.5`.

```bash
cd gb300/vanillaarm64/clustermax
./setup.sh            # 00 cluster -> 01 pool -> 02 gpu-operator -> 03 dra -> 04 dranet -> 05 nccl(all)
```

| Step | Does |
|---|---|
| `00-cluster.sh` | AKS cluster, system pool (**3× `D4s_v5`** for HA — one node loss won't take down DNS/addons/launcher), **k8s 1.35.5** (a baked version — skips the early-boot `apt-get update` that trips the arm64 CSE exit-99 false-positive) |
| `01-nodepool.sh` | GB300 pool (`Standard_ND128isr_GB300_v6`) on the vanilla arm64 custom image, `--gpu-driver None`, `sku=gpu` taint |
| `02-gpu-operator.sh` | driver (open R580) + **toolkit** + DCGM + exporter — **device plugin OFF** (GPUs come from DRA) |
| `03-dra.sh` | NVIDIA DRA driver — **GPUs** (`gpu.nvidia.com`) + **ComputeDomains** (IMEX) + controller patch |
| `04-ib-dranet.sh` | **Official dranet** (`kubernetes-sigs/dranet` `v1.3.0`) — publishes GB300 IB VFs as `dra.net` ResourceSlices for **non-privileged** IB |
| `05-nccl.sh` | NCCL `a` (intra-NVLink) / `ib-dra` (cross-node IB, dranet) / `ib` (privileged fallback) / `mnnvl` (cross-node NVLink) / `all` |

### ResourceSlices ready (after steps 03 + 04)

Once the DRA driver and dranet are up, **every GB300 node publishes three ResourceSlices** —
GPUs, ComputeDomains/IMEX, and IB NIC VFs — which is what the NCCL workloads claim:

```console
$ kubectl get resourceslices -o custom-columns=DRIVER:.spec.driver --no-headers | sort | uniq -c
  16 gpu.nvidia.com              # GPUs (DRA)             — step 03
  16 compute-domain.nvidia.com   # ComputeDomains / IMEX  — step 03
  16 dra.net                     # IB NIC VFs (dranet)    — step 04

$ kubectl get resourceslices
NODE                             DRIVER
aks-gb300-63873747-vmss000000    gpu.nvidia.com
aks-gb300-63873747-vmss000000    compute-domain.nvidia.com
aks-gb300-63873747-vmss000000    dra.net
aks-gb300-63873747-vmss000001    gpu.nvidia.com
aks-gb300-63873747-vmss000001    compute-domain.nvidia.com
aks-gb300-63873747-vmss000001    dra.net
...   (16 GB300 nodes × 3 drivers = 48 slices, all Ready)
```

## NCCL results (validated on GB300)

Bandwidth = **busbw at the 16 GB message** (large-message peak); NVLS state noted per row.

| Mode | Path | securityContext | Bandwidth |
|---|---|---|---|
| `a` | intra-node NVLink (4 GPUs via DRA) | none | **~684 GB/s** |
| `a` +NVLS | intra-node NVLS (4 GPUs, in-switch reduction) | none | **~687 GB/s** |
| `ib-dra` | cross-node IB — dranet, **aligned GPU+NIC**, 1 NIC | **`IPC_LOCK`** (non-priv) | **~56 GB/s** |
| `ib-4nic` | cross-node IB — dranet, **4 GPU + 4 aligned NICs** (Data-Direct on) | **`IPC_LOCK`** (non-priv) | **~378 GB/s** |
| `mnnvl` | cross-node NVLink P2P — 1 GPU/node (2 nodes) | privileged | **~642 GB/s** |
| `mnnvl` | cross-node NVLink P2P — 4 GPU/node (NVLS off) | privileged | **~677–698 GB/s** |
| `mnnvl` +NVLS (2-src) | cross-node NVLink multicast — 2 sources (1 GPU/node × 2 nodes) | privileged | **~663 GB/s** |
| `mnnvl` +NVLS (8-src) | cross-node NVLink multicast — 8 sources (4 GPU/node × 2 nodes) | privileged | ❌ **Xid 145** |

**NVLS boundary:** 2-source cross-node NVLS works (~663); 8-source (4 GPU/node) faults with
**Xid 145**. The **root cause is not confirmed** — we will investigate further. Keep
`NCCL_NVLS_ENABLE=0` for ≥4-GPU/node cross-node runs. (The 8-source row is **not re-run** — it
poisons GPUs.)

## The one thing that makes the toolkit work on AKS

> **`toolkit.env: RUNTIME_CONFIG_SOURCE=file`** (in `manifests/values-gpu-operator.yaml`)

AKS image `202606.19.0` ships **containerd 2.3.2** with a **version = 2** root config.
containerd 2.3 added strict validation: an imported drop-in's config version must be
**≤** the root version. The toolkit's default reads the live config via
`containerd config dump`, which on 2.3 reports **version 4**, so it writes a **v4**
drop-in (`/etc/containerd/conf.d/99-nvidia.toml`). A v4 drop-in on a v2 root is rejected:

```
containerd: drop-in config version 4 higher than root config version 2
```

→ containerd crash-loops → **every GPU node goes NotReady**. Setting
`RUNTIME_CONFIG_SOURCE=file` makes the toolkit read the **v2 root file** instead, so it
emits a **v2** drop-in that passes. Validated on GB300: nodes stay `Ready`, drop-in is
v2 (`io.containerd.grpc.v1.cri`), `nvidia`/`nvidia-cdi`/`nvidia-legacy` runtimes
registered. `02-gpu-operator.sh` hard-fails if any node flips `NotReady` after the toolkit.

## Non-privileged IB via official dranet (step 05)

The CX-usable IB path. GB300 IB VFs are **RDMA-only** (no netdev) and expose no `umad`,
so `k8s-rdma-shared-dev-plugin` can't advertise them. Instead we use **official
dranet** — the Kubernetes-SIG project `kubernetes-sigs/dranet` (`registry.k8s.io/networking/dranet`),
pinned at `v1.3.0`. It enumerates the netdev-less IB VFs (PCI fallback) and injects
their `/dev/infiniband` char devices into ordinary pods via a **DRA claim** + NRI hook.

- **`nccl-ib-dra.yaml` is non-privileged** — GPU **and** its NUMA-aligned IB NIC come from one
  DRA claim (`gpu-nic-aligned`); the only elevated bit is the `IPC_LOCK` capability (RDMA memory
  registration), *not* full privilege. A CX can copy it as-is — no host mounts.
- `nccl-ib.yaml` (privileged + hostPath `/dev/infiniband`) is kept as a **fallback**.

> **Data-Direct: on for 4-NIC, off for 1-NIC.** `NCCL_IB_DATA_DIRECT` behaves oppositely by config:
> - **4-NIC / `-g4` (`nccl-ib-4nic.yaml`): Data-Direct `=1` → ~378 GB/s** (vs ~225 off) — works at
>   the **stock memlock**, no node change needed.
> - **1-NIC / `-g1` (`nccl-ib-dra.yaml`): Data-Direct `=1` → ~0.44 GB/s collapse.** Must stay `=0` (→ ~56 GB/s).

## Privilege posture (tested on GB300)

| Test | GPU comms | securityContext | Non-priv? |
|---|---|---|---|
| `a` (`nccl-nvlink.yaml`) | intra-node NVLink | none | ✅ |
| `ib-dra` (`nccl-ib-dra.yaml`) | cross-node IB (dranet) | `IPC_LOCK` | ✅ ~56 GB/s |
| `ib` (`nccl-ib.yaml`) | cross-node IB (host-mount) | `privileged` | ❌ (fallback) |
| `mnnvl` (`nccl-mnnvl.yaml`) | cross-node NVLink (MNNVL / IMEX) | `privileged` | ❌ — see below |

**MNNVL requires `privileged` today — at every scale.** A non-privileged pod gets the IMEX channel
injected (`/dev/nvidia-caps-imex-channels/channel0`) but the collective crashes (`IPC_LOCK`,
`IPC_LOCK+SYS_ADMIN`, even `NCCL_NVLS_ENABLE=0`). Reconfirmed 2026-07-21 down to the smallest
**1-GPU/node** case (`IPC_LOCK` only → `free(): double free` in NCCL `pncclGroupEnd`), while the
identical `privileged` run does **642 GB/s**. This matches
[NVIDIA/nccl#1925](https://github.com/NVIDIA/nccl/issues/1925) (closed 2025-12-04): a non-privileged
MNNVL container failed and was resolved by **disabling MNNVL** (`NCCL_MNNVL_ENABLE=0`), not by
running it non-privileged. So the two working postures are **(a) MNNVL privileged** (~593–642 GB/s),
or **(b) MNNVL off + IB non-privileged** (`ib-dra` / `ib-4nic`). No verified non-privileged MNNVL run
exists.

*Dead end (per #1925):* `SYS_ADMIN + SYS_RESOURCE + IPC_LOCK` with Unconfined seccomp/AppArmor +
`allowPrivilegeEscalation` was tried and still failed — capability/seccomp tweaks don't help. The
only untried avenues are a fully-configured IMEX domain or a newer NVIDIA DRA driver.

## Notes / AKS specifics

- **DCGM + dcgm-exporter** are on (GPU metrics, Prometheus-scrapeable). They're
  monitoring only — independent of how GPUs reach pods.
- **`nvidia-peermem` is not used** — the inbox `linux-azure-nvidia` kernel provides
  GPUDirect RDMA via **dmabuf** (Data-Direct); no OFED needed (`driver.rdma.enabled=false`).

Cleanup: `./cleanup.sh` (deletes the RG) or `KEEP_RG=1 ./cleanup.sh` (charts only).

## Why the optional GB300 system pool

On the dev subscription, idle VMs — including the cheap `D4s_v5` system pool — can get
**deallocated**, which takes cluster DNS/addons down. GB300 is exempt, so `SYSTEM_ON_GB300=1` uses
**GB300 as the system pool** to keep the cluster always-on. **Be aware this is not a normal setup**
(a GB300 system pool is expensive, dev-only); the default ships a normal `D4s_v5` system pool.

## Roadmap: AKS managed GPU experience for GB200/GB300 — next 2–3 months

This route is the **manual / BYO validation** — GPU-operator driver + NVIDIA DRA + dranet +
ComputeDomains, wired by hand. The productized path is the AKS **[managed GPU experience
(preview)](https://learn.microsoft.com/en-us/azure/aks/aks-managed-gpu-nodes)**: with
`--enable-managed-gpu=true` (feature `ManagedGPUExperiencePreview`) AKS installs and maintains the
driver + **device plugin** + DCGM exporter + GPU health signals in **NPD**
(`UnhealthyNvidiaDevicePlugin`, `UnhealthyNvidiaDCGMServices`) — today device-plugin based, for
device-plugin GPU SKUs (T4/A100/H100…).

**We're extending the managed GPU experience to GB200/GB300 (NVLink)**, where device-plugin
scheduling isn't enough; providing the managed equivalents of what this route wires by hand:
- **Managed DRA** — GPUs published as `gpu.nvidia.com` ResourceSlices (not `nvidia.com/gpu`), so a
  workload can claim a GPU **+ its NUMA-aligned IB NIC** in one request.
- **Managed dranet** — GB300 IB NIC VFs published as `dra.net` ResourceSlices for non-privileged IB
  (the GPU+NIC aligned claim above).
- **Managed ComputeDomains** — IMEX channels for cross-node NVLink (MNNVL).
- **NPD** — GPU health signals extended to the DRA / dranet / ComputeDomain components.

Goal: a customer gets the full GB200/GB300 stack **managed by AKS** instead of the manual
GPU-operator + DRA + dranet setup this route documents.
