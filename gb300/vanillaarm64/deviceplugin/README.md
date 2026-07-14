# GB300 on the vanilla arm64 AKS image — end-to-end GPU setup

Takes an AKS cluster from **nothing** to the **final validated state** on the stock
**vanilla arm64 Ubuntu 24.04** image (`2404gen2arm64containerd`), then runs the full
NCCL matrix. No bespoke GB VHD, **no OFED, no nvidia-peermem**.

```bash
cd gb300/vanillaarm64/deviceplugin
# edit variables.sh (subscription / rg / cluster / counts) or override via env
./setup.sh            # nodepool -> gpu-operator(driver) -> imex -> nccl(all)
```

Or run steps individually:

```bash
./01-nodepool.sh      # GB300 pool on vanilla arm64 (--gpu-driver None, sku=gpu taint)
./02-gpu-operator.sh  # GPU Operator, DRIVER ONLY (toolkit OFF) -> open R580 DKMS build
./03-imex.sh          # create IMEX channel + peer list + start nvidia-imex on every node
./04-nccl.sh all      # a=intra NVLink, b=cross-node IB, c=cross-node MNNVL
./cleanup.sh [--nodepool]
```

## Validated results (Standard_ND128isr_GB300_v6, open R580 580.105.08)

| Path | Transport | busbw |
|---|---|---|
| A — intra-node NVLink (4 GPU) | NVLS + P2P | ~612 GB/s |
| B — cross-node IB / RDMA | `NET/IB` Data-Direct, **GPUDirect RDMA (DMABUF)**, 4× CX-8 | ~88 GB/s |
| C — cross-node NVLink (MNNVL) | NVLS/MNNVL over IMEX (`NCCL_IB_DISABLE=1`) | ~595 GB/s |

## Why this looks different from Anson's stack (important)

This does **not** use the k8s device plugin, DRA, dranet, the container-toolkit, or OFED.
Those were tried and are blocked on AKS; the working path is **direct driver-mount**:

- **GPU Operator container-toolkit breaks AKS containerd.** It rewrites
  `/etc/containerd/config.toml` (reformats + prepends `imports = conf.d/*.toml`) and
  crash-loops AKS containerd 2.3.2 → nodes NotReady. So we install the operator with
  **`toolkit.enabled=false`** (driver only). The device plugin / DCGM / GFD depend on
  `toolkit-validation`, so they stay disabled too.
- **GPU injection is by mounting the driver rootfs** (`hostPath /run/nvidia/driver` + `/dev`,
  `privileged`, `LD_LIBRARY_PATH += .../usr/lib/aarch64-linux-gnu`). `libcuda`, `nvidia-smi`
  and NCCL all resolve. See `manifests/nccl-*.yaml`.
- **No nvidia-peermem** — the inbox `linux-azure-nvidia` `ib_core` dropped the legacy
  peer-memory API (`modprobe nvidia-peermem` → `Invalid argument`). GDR uses the inbox
  **dmabuf** path instead, which NCCL auto-selects (`GPU Direct RDMA (DMABUF) enabled`).
- **No hostNetwork** — AKS uses shared-RDMA-netns mode, so privileged pods get IB without
  it (and it avoids the sshd port-22 clash under mpi-operator).
- **IMEX is manual** — the `nvidia-imex` binary ships in the operator driver container, but
  the channel device, peer list, and daemon are not set up on the vanilla image. `03-imex.sh`
  does that per node (`mknod` the channel, write `nodes_config.cfg`, start the daemon). In
  production the GPU Operator's **ComputeDomains** (DRA) automates this — but it needs the
  toolkit, hence manual here.

The folder is named `deviceplugin` to contrast with a future `dra` variant; the *mechanism*
that actually reaches the final state on AKS today is direct driver-mount.

## Files

| File | Purpose |
|---|---|
| `variables.sh` | all config (env-overridable) + logging helpers |
| `01-nodepool.sh` | create GB300 pool on the pinned vanilla arm64 image |
| `02-gpu-operator.sh` | install GPU Operator (driver only) + verify `nvidia-smi` |
| `03-imex.sh` | IMEX channel + peer list + daemon on every GB node |
| `04-nccl.sh` | run NCCL Path A/B/C |
| `manifests/values-gpu-operator.yaml` | driver-only operator values |
| `manifests/nccl-nvlink.yaml` | Path A pod (intra-node NVLink) |
| `manifests/nccl-ib.yaml` | Path B MPIJob (cross-node IB) |
| `manifests/nccl-mnnvl.yaml` | Path C MPIJob (cross-node MNNVL) |
| `setup.sh` / `cleanup.sh` | one-shot orchestrator / teardown |

## Prerequisites

`az` (logged in, with the target subscription), `kubectl`, `helm`, and the AKS cluster
already created (this only adds the GPU node pool). GB300 lives in a capacity-constrained
pinned availability set — 18 requested may land fewer; ≥2 Ready is enough for all paths.
