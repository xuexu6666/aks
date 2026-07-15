# GB300 on vanilla arm64 — clustermax full-stack (toolkit + device plugin + DCGM + DRA)

The **managed-experience** variant. Where `../deviceplugin` runs the toolkit OFF (and
mounts the driver by hand) and `../dra` uses pure DRA, this one installs the **whole
GPU Operator stack** — driver + **container-toolkit** + device plugin + **DCGM** +
**dcgm-exporter** — plus the **DRA driver for ComputeDomains** (cross-node NVLink), and
runs NCCL. Same vanilla arm64 image (`2404gen2arm64containerd 202606.19.0`), k8s `1.35.5`.

```bash
cd gb300/vanillaarm64/clustermax
./setup.sh            # 00 cluster -> 01 pool -> 02 gpu-operator -> 03 dra -> 04 nccl(all)
```

| Step | Does |
|---|---|
| `00-cluster.sh` | AKS cluster, system pool (`D4s_v5`), **k8s 1.35.5** (a baked version — skips the early-boot `apt-get update` that trips the arm64 CSE exit-99 false-positive) |
| `01-nodepool.sh` | GB300 pool (`Standard_ND128isr_GB300_v6`) on the vanilla arm64 custom image, `--gpu-driver None`, `sku=gpu` taint |
| `02-gpu-operator.sh` | **Full stack**: driver (open R580) + **toolkit** + device plugin + DCGM + exporter |
| `03-dra.sh` | DRA driver, **ComputeDomains only** (coexists with the device plugin) + controller patch |
| `04-nccl.sh` | NCCL `a` (intra-NVLink) / `ib` (cross-node IB) / `mnnvl` (cross-node NVLink) / `all` |

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

## Notes / AKS specifics

- **DCGM + dcgm-exporter** are on (GPU metrics, Prometheus-scrapeable). They're
  monitoring only — independent of how GPUs reach pods.
- **`nvidia-peermem` is not used** — the inbox `linux-azure-nvidia` kernel provides
  GPUDirect RDMA via **dmabuf** (Data-Direct); no OFED needed (`driver.rdma.enabled=false`).
- **IB (Path B)** mounts `/dev/infiniband` directly — GB300 IB VFs expose no `umad`, so
  `k8s-rdma-shared-dev-plugin` can't advertise a resource.
- The **MPI launcher runs on a non-GPU (system) node** — the GB nodes' NRI/driver setup
  disturbs the OpenMPI OOB callback.
- **k8s must be a baked version** (`1.35.5` for `202606.19.0`) so the node skips
  `apt-get update` at bootstrap.

## Expected NCCL results
`a` intra-NVLink **~620 GB/s** · `ib` cross-node IB **~88 GB/s** · `mnnvl` cross-node NVLink **~595 GB/s**

Cleanup: `./cleanup.sh` (deletes the RG) or `KEEP_RG=1 ./cleanup.sh` (charts only).
