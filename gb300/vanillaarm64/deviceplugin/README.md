# GB300 on the vanilla arm64 AKS image — device-plugin GPU setup

Takes an AKS cluster from **nothing** to the **final validated state** on the stock
**vanilla arm64 Ubuntu 24.04** image (`2404gen2arm64containerd`), using the
**device-plugin model** (pods request `nvidia.com/gpu` / `rdma/shared_ib`), then
runs the NCCL matrix. No bespoke GB VHD, **no OFED, no peermem**, and — crucially —
**without letting the GPU-operator toolkit break AKS containerd**.

```bash
cd gb300/vanillaarm64/deviceplugin
# edit variables.sh (subscription / rg / cluster / counts) or override via env
./setup.sh   # 00 cluster -> 01 nodepool -> 02 driver -> 03 runtime -> 04 device-plugin -> 05 imex -> 06 nccl
```

Individual steps:

```bash
./00-cluster.sh        # resource group + AKS cluster (system pool)   [skip if cluster exists]
./01-nodepool.sh       # GB300 pool on vanilla arm64 (--gpu-driver None, sku=gpu taint)
./02-gpu-operator.sh   # GPU Operator, DRIVER ONLY (toolkit off) -> open R580 DKMS build
./03-nvidia-runtime.sh # install toolkit binaries + wire nvidia runtime into containerd (AKS-native)
./04-device-plugin.sh  # nvidia.com/gpu (+ rdma/shared_ib) device plugins  [WITH_RDMA=false to skip IB]
./05-imex.sh           # IMEX per node (cross-node NVLink / MNNVL)
./06-nccl.sh all       # a=intra NVLink, b=cross-node IB, c=cross-node MNNVL
./cleanup.sh [--nodepool]
```

## The device-plugin model — how GPUs reach pods

This is the same pattern AKS's own **fully-managed GPU experience** uses (see
AgentBaker `cse_config.sh:startNvidiaManagedExpServices` +
`parts/linux/cloud-init/artifacts/ubuntu/gb/containerd-nvidia.toml`):

1. **Driver** — GPU Operator installs the open R580 driver only (`toolkit.enabled=false`).
2. **nvidia runtime in containerd** — `03-nvidia-runtime.sh` installs the toolkit
   *binaries* and **additively** appends an `nvidia` runtime table to AKS's
   `config.toml` (fully-qualified TOML table → containerd stays healthy), in
   **`legacy` mode** (prestart hook → `nvidia-container-cli` injects libs+devices
   from `driverRoot=/run/nvidia/driver`).
3. **device plugin** — `nvidia-device-plugin` DaemonSet runs with
   `runtimeClassName: nvidia` (so the runtime injects NVML into the plugin pod →
   it enumerates GPUs) and advertises **`nvidia.com/gpu`**.
4. **workloads** — a normal pod sets `runtimeClassName: nvidia` and requests
   `nvidia.com/gpu`; GPUs + driver libs are injected by the runtime. **No
   privileged, no hostPath, no direct driver-mount.**

For cross-node IB (Path B), the **`k8s-rdma-shared-dev-plugin`** advertises
`rdma/shared_ib`; a worker requests it and gets `/dev/infiniband` (all 4 CX-8
NICs, shared mode) without hostNetwork (AKS shared RDMA-netns).

## ⚠️ Why NOT the GPU-operator toolkit / CDI

The GPU Operator's container-toolkit (`nvidia-ctk runtime configure`, in default
**or** CDI mode) **rewrites** AKS's `/etc/containerd/config.toml` (reformats it +
prepends `imports = conf.d/*.toml`) and **crash-loops containerd 2.3.2** → nodes
NotReady. So we keep `toolkit.enabled=false` and add the runtime **additively**
ourselves — the one step done differently from the operator. The device
plugin/DCGM/GFD operands also depend on `toolkit-validation`, so they stay off;
we run a standalone device plugin instead.

`nvidia-peermem` is likewise skipped — the inbox `linux-azure-nvidia` kernel
dropped the legacy peer-memory API (`modprobe` → `Invalid argument`); GDR uses
the inbox **dmabuf** path, which NCCL auto-selects.

## Validation status (Standard_ND128isr_GB300_v6, open R580 580.105.08)

| Path | Mechanism | Result | Status |
|---|---|---|---|
| A — intra-node NVLink (4 GPU) | device plugin: `nvidia.com/gpu:4`, runtimeClass nvidia | **~620 GB/s** | ✅ validated on-cluster via device plugin |
| B — cross-node IB / RDMA | device plugin: `nvidia.com/gpu:1` + `rdma/shared_ib:1` | ~88 GB/s (dmabuf GDR) | GPU-injection = same as A (validated); RDMA plugin advertises the resource; the ~88 GB/s number was confirmed via the direct-mount equivalent |
| C — cross-node NVLink (MNNVL) | device plugin GPU + IMEX + channel mount | ~595 GB/s | GPU-injection validated; MNNVL/IMEX confirmed via the direct-mount equivalent |

The **runtime wiring**, **device plugin (`nvidia.com/gpu`)**, and **Path A** were
validated end-to-end on the cluster via the device-plugin model. B/C reuse the
identical GPU-injection path; their IB/IMEX transports were proven on the same
nodes (see the direct-mount history / the wiki writeup).

## Files

| File | Purpose |
|---|---|
| `variables.sh` | config (env-overridable) + helpers |
| `00-cluster.sh` | resource group + AKS cluster (system pool) |
| `01-nodepool.sh` | GB300 pool on the pinned vanilla arm64 image |
| `02-gpu-operator.sh` | GPU Operator (driver only) + verify `nvidia-smi` |
| `03-nvidia-runtime.sh` | install toolkit binaries + additively wire nvidia runtime into containerd + RuntimeClass |
| `04-device-plugin.sh` | deploy `nvidia-device-plugin` (+ `rdma-shared-dev-plugin`); verify capacity |
| `05-imex.sh` | IMEX channel + peer list + daemon per node |
| `06-nccl.sh` | run NCCL Path A/B/C |
| `manifests/values-gpu-operator.yaml` | driver-only operator values |
| `manifests/runtimeclass-nvidia.yaml` | `nvidia` RuntimeClass |
| `manifests/toolkit-install-daemonset.yaml` | install toolkit binaries (no containerd config) |
| `manifests/nvidia-device-plugin.yaml` | GPU device plugin (runtimeClass nvidia) |
| `manifests/rdma-shared-dev-plugin.yaml` | RDMA shared device plugin (`rdma/shared_ib`) |
| `manifests/nccl-{nvlink,ib,mnnvl}.yaml` | NCCL Path A/B/C (device-plugin model) |
| `setup.sh` / `cleanup.sh` | orchestrator / teardown |

## Prerequisites

`az` (logged in), `kubectl`, `helm`, Kubernetes ≥ 1.31. `00-cluster.sh` creates the
resource group + cluster (or skips if they exist); `01-nodepool.sh` adds the GPU
pool. GB300 lives in a capacity-constrained pinned
availability set — 18 requested may land fewer; ≥2 Ready is enough for all paths.

## Per-NIC isolation (not this folder)

The shared RDMA plugin gives every pod *all* NICs. For **one dedicated NIC per pod**
+ **GPU↔NIC NUMA alignment**, use **DRA**: `nvidia-dra-driver-gpu` (GPUs) +
`dranet` (`dra.net`) co-allocated in one ResourceClaim, with ComputeDomains for
MNNVL. On AKS GB300 the alignment (`pcieRoot`) is not yet resolvable (VMBUS paths)
and the IB-only dranet support needs a fork — tracked as a separate `dra/` variant.
