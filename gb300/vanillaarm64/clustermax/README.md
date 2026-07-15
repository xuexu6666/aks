# GB300 on vanilla arm64 — clustermax full-stack (toolkit + device plugin + DCGM + DRA)

The **managed-experience** variant. Where `../deviceplugin` runs the toolkit OFF (and
mounts the driver by hand) and `../dra` uses pure DRA, this one installs the **whole
GPU Operator stack** — driver + **container-toolkit** + device plugin + **DCGM** +
**dcgm-exporter** — plus the **DRA driver for ComputeDomains** (cross-node NVLink) and
**official dranet** (non-privileged cross-node IB), and runs NCCL. Same vanilla arm64
image (`2404gen2arm64containerd 202606.19.0`), k8s `1.35.5`.

```bash
cd gb300/vanillaarm64/clustermax
./setup.sh            # 00 cluster -> 01 pool -> 02 gpu-operator -> 03 dra -> 04 dranet -> 05 nccl(all)
```

| Step | Does |
|---|---|
| `00-cluster.sh` | AKS cluster, system pool (`D4s_v5`), **k8s 1.35.5** (a baked version — skips the early-boot `apt-get update` that trips the arm64 CSE exit-99 false-positive) |
| `01-nodepool.sh` | GB300 pool (`Standard_ND128isr_GB300_v6`) on the vanilla arm64 custom image, `--gpu-driver None`, `sku=gpu` taint |
| `02-gpu-operator.sh` | **Full stack**: driver (open R580) + **toolkit** + device plugin + DCGM + exporter |
| `03-dra.sh` | DRA driver, **ComputeDomains only** (coexists with the device plugin) + controller patch |
| `04-ib-dranet.sh` | **Official dranet** (`kubernetes-sigs/dranet` `v1.3.0`) — publishes GB300 IB VFs as `dra.net` ResourceSlices for **non-privileged** IB |
| `05-nccl.sh` | NCCL `a` (intra-NVLink) / `ib-dra` (cross-node IB, dranet) / `ib` (privileged fallback) / `mnnvl` (cross-node NVLink) / `all` |

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

## Device plugin + DRA coexistence

- **Device plugin owns GPU allocation** (`nvidia.com/gpu`, injected by the `nvidia` runtime).
- **DRA is ComputeDomains-only** (`gpuResourcesEnabledOverride: false`) — it does *not*
  publish GPU ResourceSlices, so the two never double-allocate a GPU. DRA supplies the
  **IMEX channel** for cross-node NVLink (MNNVL), which the device plugin can't.
- MNNVL workers therefore claim **both** `nvidia.com/gpu: 1` (device plugin) and the
  `nccl-cd-channel` DRA claim (ComputeDomains). See `manifests/nccl-mnnvl.yaml`.

## Non-privileged IB via official dranet (step 05)

The CX-usable IB path. GB300 IB VFs are **RDMA-only** (no netdev) and expose no `umad`,
so `k8s-rdma-shared-dev-plugin` can't advertise them. Instead we use **official
dranet** — the Kubernetes-SIG project `kubernetes-sigs/dranet` (`registry.k8s.io/networking/dranet`),
pinned at `v1.3.0`. It enumerates the netdev-less IB VFs (PCI fallback) and injects
their `/dev/infiniband` char devices into ordinary pods via a **DRA claim** + NRI hook.

- **This is Anson's IB-only support, now upstream** — his `add-support-for-ib-only-rdma-device`
  work merged into the SIG repo as **PR #77** ("Add IB-only RDMA device support and AKS
  GB300 example"). No personal fork (`ghcr.io/anson627/dranet`) needed anymore.
- **`nccl-ib-dra.yaml` is non-privileged** — GPU via the device plugin (`nvidia.com/gpu`),
  IB NIC via the `ib-nic` DRA claim; the only elevated bit is the `IPC_LOCK` capability
  (RDMA memory registration), *not* full privilege. A CX can copy it as-is — no host mounts.
- `nccl-ib.yaml` (privileged + hostPath `/dev/infiniband`) is kept as a **fallback**.

**Verified on the live GB300 cluster (14 nodes):** official dranet `v1.3.0` publishes
all four IB VFs per node — `mlx5_0..mlx5_3`, `dra.net/rdma=true`, **no `ifName`**
(netdev-less, the IB-only case) — 56 RDMA devices across 14 nodes. A **non-privileged**
worker (`IPC_LOCK` only) received `/dev/infiniband/uverbs2`, `ibv_devices` listed
`mlx5_0`, and NCCL ran over it with `NET/IB Data Direct` + `GPU Direct RDMA (DMABUF)`.

> **memlock caveat (perf).** `IPC_LOCK` permits locking but does **not** raise the
> memlock *rlimit*. AKS nodes default to `max locked memory = 8192 KB`, which caps RDMA
> registration and throttles NCCL to **~0.43 GB/s**. Full bandwidth needs the node's
> containerd to expose unlimited memlock (`LimitMEMLOCK=infinity` drop-in → pod sees
> `ulimit -l unlimited`). The privileged `nccl-ib.yaml` sidesteps this because privileged
> containers get unlimited memlock implicitly. **The full-BW non-privileged number is not
> yet cleanly validated** — raising node memlock lifted `ulimit -l` to unlimited but the
> collective then hit an intermittent `unhandled system error` right after a live
> containerd restart; needs a clean re-test (fresh nodes with the drop-in baked in).

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

## Expected NCCL results
`a` intra-NVLink **~620 GB/s** · `ib` (privileged) cross-node IB **~88 GB/s** · `mnnvl` cross-node NVLink **~595 GB/s**
`ib-dra` (non-privileged, official dranet): **functional** (IB GDRDMA confirmed); full-BW number pending the memlock re-test (see caveat above).

Cleanup: `./cleanup.sh` (deletes the RG) or `KEEP_RG=1 ./cleanup.sh` (charts only).
