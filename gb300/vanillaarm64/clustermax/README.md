# GB300 on vanilla arm64 — clustermax full-stack (toolkit + GPU-DRA + DCGM + dranet)

The **full-stack** variant. Installs driver (open R580) + **container-toolkit** + **DCGM** +
**dcgm-exporter** from the GPU Operator (**device plugin OFF**), the **NVIDIA GPU DRA driver**
(GPUs as `gpu.nvidia.com` ResourceSlices + ComputeDomains for MNNVL), and **official dranet**
(IB NICs as `dra.net` ResourceSlices). GPUs come from **DRA, not the device plugin**, so a
workload claims a GPU and its aligned IB NIC in one DRA request → **~56 GB/s/NIC** non-privileged
IB (vs ~25 GB/s when the GPU and NIC land apart). Same vanilla arm64 image
(`2404gen2arm64containerd 202606.19.0`), k8s `1.35.5`.

```bash
cd gb300/vanillaarm64/clustermax
./setup.sh            # 00 cluster -> 01 pool -> 02 gpu-operator -> 03 dra -> 04 dranet -> 05 nccl(all)
```

| Step | Does |
|---|---|
| `00-cluster.sh` | AKS cluster, system pool (`D4s_v5`), **k8s 1.35.5** (a baked version — skips the early-boot `apt-get update` that trips the arm64 CSE exit-99 false-positive) |
| `01-nodepool.sh` | GB300 pool (`Standard_ND128isr_GB300_v6`) on the vanilla arm64 custom image, `--gpu-driver None`, `sku=gpu` taint |
| `02-gpu-operator.sh` | driver (open R580) + **toolkit** + DCGM + exporter — **device plugin OFF** (GPUs come from DRA) |
| `03-dra.sh` | NVIDIA DRA driver — **GPUs** (`gpu.nvidia.com`) + **ComputeDomains** (IMEX) + controller patch |
| `04-ib-dranet.sh` | **Official dranet** (`kubernetes-sigs/dranet` `v1.3.0`) — publishes GB300 IB VFs as `dra.net` ResourceSlices for **non-privileged** IB |
| `05-nccl.sh` | NCCL `a` (intra-NVLink) / `ib-dra` (cross-node IB, dranet) / `ib` (privileged fallback) / `mnnvl` (cross-node NVLink) / `all` |

## NCCL results (validated on GB300)

| Mode | Path | securityContext | Bandwidth |
|---|---|---|---|
| `a` | intra-node NVLink (4 GPUs via DRA) | none | **~650 GB/s** |
| `ib-dra` | cross-node IB — dranet, **aligned GPU+NIC**, 1 NIC | **`IPC_LOCK`** (non-priv) | **~56 GB/s** |
| `ib` | cross-node IB — host-mount, 4 NICs | privileged | **~88 GB/s** |
| `mnnvl` | cross-node NVLink (MNNVL / IMEX) | privileged | **~593 GB/s** |

`ib-dra` is the CX-usable path — **non-privileged**, no host mounts. Claiming the GPU **and** NIC
in one DRA request keeps them together (GDR) → **~56 GB/s/NIC**; picking them apart drops to ~25 GB/s.
A 2-NIC aligned claim ≈ ~112 GB/s. `NCCL_IB_DATA_DIRECT=0` is set to keep it healthy.
See "Privilege posture" for the MNNVL privileged caveat.

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

## Why GPUs go through DRA (not the device plugin)

- **Device plugin OFF; the GPU DRA driver owns GPUs** (`resources.gpus.enabled=true` +
  `gpuResourcesEnabledOverride=true`, `values-dra.yaml`) — they can't both allocate GPUs.
- **Why:** DRA lets you claim the **GPU and its IB NIC in one request** (`gpu-nic-aligned`:
  `gpu-0` + `mlx5_0`), so they land together → GDR → **~56 GB/s/NIC**. The device plugin resolves
  GPU and NIC independently → they land apart → **~25 GB/s** (same split as the upstream GB300 example).
- GB300 topology (fixed): `gpu-0/1`+`mlx5_0/1` together, `gpu-2/3`+`mlx5_2/3` together. Claim
  templates in `manifests/dra-claims.yaml` (`gpus-4`, `gpu-nic-aligned`, `gpu-1`).
- **MNNVL** workers claim a GPU (`gpu-1`, DRA) **plus** the `nccl-cd-channel` DRA claim (ComputeDomains IMEX).

## Non-privileged IB via official dranet (step 05)

The CX-usable IB path. GB300 IB VFs are **RDMA-only** (no netdev) and expose no `umad`,
so `k8s-rdma-shared-dev-plugin` can't advertise them. Instead we use **official
dranet** — the Kubernetes-SIG project `kubernetes-sigs/dranet` (`registry.k8s.io/networking/dranet`),
pinned at `v1.3.0`. It enumerates the netdev-less IB VFs (PCI fallback) and injects
their `/dev/infiniband` char devices into ordinary pods via a **DRA claim** + NRI hook.

- **This is Anson's IB-only support, now upstream** — his `add-support-for-ib-only-rdma-device`
  work merged into the SIG repo as **PR #77** ("Add IB-only RDMA device support and AKS
  GB300 example"). No personal fork (`ghcr.io/anson627/dranet`) needed anymore.
- **`nccl-ib-dra.yaml` is non-privileged** — GPU **and** its NUMA-aligned IB NIC come from one
  DRA claim (`gpu-nic-aligned`); the only elevated bit is the `IPC_LOCK` capability (RDMA memory
  registration), *not* full privilege. A CX can copy it as-is — no host mounts.
- `nccl-ib.yaml` (privileged + hostPath `/dev/infiniband`) is kept as a **fallback**.

**Verified end-to-end on a fresh 18-node GB300 cluster:** official dranet `v1.3.0`
publishes all four IB VFs per node — `mlx5_0..mlx5_3`, `dra.net/rdma=true`, **no
`ifName`** (netdev-less, the IB-only case). A **non-privileged** worker (`IPC_LOCK`
only) received `/dev/infiniband`, `ibv_devices` listed the VF, and a 2-node NCCL
all-reduce ran over it at **~25 GB/s (single NIC)** via `NET/IB` + GPU Direct RDMA —
**with no node changes at all**.

> **memlock: a minor tune, not a blocker.** Early on, a *different* flag combination
> (`NCCL_IB_DATA_DIRECT` on) collapsed to **~0.43 GB/s** on the 8 MB-memlock default,
> which looked like a hard memlock wall. It wasn't: setting **`NCCL_IB_DATA_DIRECT=0`**
> (the upstream GB300 setting, now in `nccl-ib-dra.yaml`) gives **~25 GB/s single-NIC
> with the stock 8192 KB memlock and `IPC_LOCK` only** — no node change needed.
> Raising node memlock to unlimited (`LimitMEMLOCK=infinity` containerd drop-in →
> pod sees `ulimit -l unlimited`) lifts it to **~28 GB/s (~11%)** — a nice-to-have,
> not a requirement. (Apply it via a fresh boot / node-image bake, **not** a live
> containerd restart under load — that path intermittently wedged the collective.)
>
> Single-NIC ~25–28 GB/s matches the privileged `nccl-ib.yaml`'s ~88 GB/s being
> **four** NICs (`NCCL_IB_HCA=mlx5`, ~22 GB/s/NIC). For full non-privileged
> bandwidth, claim 4 NICs (see the upstream `4nic-aligned` template) — TODO here.

## Privilege posture (tested on GB300)

| Test | GPU comms | securityContext | Non-priv? |
|---|---|---|---|
| `a` (`nccl-nvlink.yaml`) | intra-node NVLink | none | ✅ |
| `ib-dra` (`nccl-ib-dra.yaml`) | cross-node IB (dranet) | `IPC_LOCK` | ✅ ~25 GB/s |
| `ib` (`nccl-ib.yaml`) | cross-node IB (host-mount) | `privileged` | ❌ (fallback) |
| `mnnvl` (`nccl-mnnvl.yaml`) | cross-node NVLink (MNNVL/CUMEM fabric; NVLS on top) | `privileged` | ❌ — see below |

**MNNVL: privileged is what works today; non-privileged is NVIDIA's *intent* but not
a confirmed reality.** NVIDIA's ComputeDomains design goal is to run MNNVL
**non-privileged** (the DRA driver injects the IMEX channel and treats it as an
implementation detail), and CoreWeave's GB200 docs show an MNNVL worker with
`privileged: false`. Note: that CoreWeave example uses **no added capabilities at all** —
`IPC_LOCK` is an **IB/RDMA** memory-pinning requirement (from the `ib-dra` path), not a
documented IMEX/NVLink one; don't assume it's the MNNVL unlock. Caveat: I found **no
bandwidth-verified non-privileged MNNVL run** published anywhere — the non-priv posture
is documented *intent*, not a confirmed passing result.

On our GB300 the non-privileged pod got the IMEX channel injected
(`/dev/nvidia-caps-imex-channels/channel0`) but the collective still crashed with
`IPC_LOCK`, `IPC_LOCK+SYS_ADMIN`, and even `NCCL_NVLS_ENABLE=0`; `privileged` runs at
**~593 GB/s**. This matches open bug [NCCL #1925](https://github.com/NVIDIA/nccl/issues/1925)
(Nov 2025): `Cuda failure 800 'operation not permitted'` on the IMEX-channel path, where
`privileged: true` is the reporter's confirmed workaround — unresolved upstream. (That
report is on **GB200**; our crash is **GB300** — a reasonable cross-platform match, but
an inference.) So privileged looks like a **bug/config gap** rather than an inherent
requirement — but no non-privileged fix is confirmed anywhere yet.

*Known NOT to work (per #1925):* `SYS_ADMIN + SYS_RESOURCE + IPC_LOCK + SYS_NICE` with
**seccomp/AppArmor `Unconfined`** + `allowPrivilegeEscalation` — the reporter tried that
exact combo and it **still failed**. So capability/seccomp tweaks are a dead end. The
only genuinely untried avenues are a **fully-configured IMEX domain** or a **newer
NVIDIA DRA driver**. (Anson sidesteps MNNVL entirely — his upstream runs **IB-only**
with `NCCL_MNNVL_ENABLE=0` / `NCCL_NVLS_ENABLE=0`.)

## Notes / AKS specifics

- **DCGM + dcgm-exporter** are on (GPU metrics, Prometheus-scrapeable). They're
  monitoring only — independent of how GPUs reach pods.
- **`nvidia-peermem` is not used** — the inbox `linux-azure-nvidia` kernel provides
  GPUDirect RDMA via **dmabuf** (Data-Direct); no OFED needed (`driver.rdma.enabled=false`).
- **NRI needs no setup** — containerd 2.x enables NRI by default; AKS's 2.3.2 inherits it
  (`containerd config dump` → `io.containerd.nri.v1.nri disable=false`, and
  `/var/run/nri/nri.sock` exists — set by no config file, it's the built-in default).
  dranet is an NRI plugin and just connects.
- The **MPI launcher runs on a non-GPU (system) node** — the GB nodes' NRI/driver setup
  disturbs the OpenMPI OOB callback.
- **k8s must be a baked version** (`1.35.5` for `202606.19.0`) so the node skips
  `apt-get update` at bootstrap.

Cleanup: `./cleanup.sh` (deletes the RG) or `KEEP_RG=1 ./cleanup.sh` (charts only).
