# GB300 on the vanilla arm64 AKS image — DRA + dranet variant

The **DRA** path (Anson's approach): allocate a **GPU + its IB NIC together** in one
`ResourceClaim` via two DRA drivers — `nvidia-dra-driver-gpu` (GPUs) and **dranet**
(IB NICs) — instead of the device-plugin model. Same vanilla arm64 image, same
driver-only GPU Operator; the difference is how GPUs/NICs reach pods.

```bash
cd gb300/vanillaarm64/dra
./setup.sh   # 00 cluster -> 01 nodepool -> 02 driver -> 03 NRI -> 04 dra+dranet -> 05 nccl
```

| Step | Does |
|---|---|
| `00-cluster.sh` / `01-nodepool.sh` / `02-gpu-operator.sh` | same as the device-plugin variant (cluster, GB300 pool on vanilla arm64, driver-only GPU Operator → open R580) |
| `03-nri.sh` | **enable NRI in containerd** on every node (dranet is an NRI plugin; AKS containerd 2.3.2 ships NRI disabled). Added additively → containerd stays healthy. |
| `04-dra-dranet.sh` | `helm install nvidia-dra-driver-gpu` (GPU `ResourceSlices`) + deploy **dranet** (NIC `ResourceSlices`); retarget dranet's nodeSelector to our pool. |
| `05-nccl-dra.sh` | mpi-operator + `DeviceClass` + `gpu-nic-aligned` `ResourceClaimTemplate` + MPIJob (each worker claims 1 GPU + its aligned NIC). |

## What works (validated on-cluster)

- ✅ **`nvidia-dra-driver-gpu`** publishes **13 GPU `ResourceSlices`** (`gpu.nvidia.com`), each device with `pciBusID` (`0008/0009/0018/0019:06:00.0`).
- ✅ **dranet** publishes **13 NIC `ResourceSlices`** (`dra.net`), each with `pciAddress` (`0101–0104:00:00.0`), `ifName` empty (IB-only VFs, no netdev — confirms Anson's fork handles IB-only devices).
- ✅ The **`gpu-nic-aligned` claim allocates** — `kubectl get resourceclaims` shows `allocated,reserved`; the DRA scheduler co-selects a GPU (`0008:06:00.0`) + its NIC (`0101:00:00.0`) and injects both into the worker pod, which runs.

So the **DRA allocation + injection works end-to-end** — the hard part that Anson's
dranet fork enables for AKS IB-only VFs.

## ✅ Cross-node NCCL — WORKING (both paths)

Run: `./05-nccl-dra.sh ib` | `mnnvl` | `both`.

**Path B — cross-node IB / RDMA (~88 GB/s)** — DRA `gpu-nic-aligned` claim (GPU + IB NIC):
```
NET/IB: Data Direct DMA Interface detected for mlx5_0..3
GPU Direct RDMA (DMABUF) enabled
# Avg bus bandwidth : 88.16 GB/s   (exit 0)
```
GPU **and** its IB NIC co-allocated by DRA (`allocated,reserved`); dranet injects the NIC's RDMA devices.

**Path C — cross-node NVLink / MNNVL (~595 GB/s)** — DRA **ComputeDomains** (automated IMEX):
```
via P2P / NVLS (NCCL_IB_DISABLE=1)
# Avg bus bandwidth : 594.9 GB/s   (exit 0)
```
The `ComputeDomain` CR makes the DRA driver create the `nccl-cd-channel` claim template
and run the **IMEX daemons across the workers automatically** — the DRA equivalent of
the device-plugin variant's manual `nvidia-imex` bring-up (no `/etc/nvidia-imex` config).
Each worker claims a **GPU + the CD channel**; IB disabled → NVLink/NVLS transport.

> **ComputeDomains gotcha on AKS:** the DRA driver's CD *controller* ships with a
> hardcoded affinity for `node-role.kubernetes.io/control-plane` nodes, which don't
> exist on AKS (managed control plane) — it stays Pending and never creates the
> channel template. `04-dra-dranet.sh` patches the controller onto a system node.

### The one gotcha: the Launcher must run on a NON-GPU node

The earlier failure (`ORTE ... no route to worker`, "no connection back to mpirun")
was **not** a broken pod network — on-node `nsenter` confirmed the worker keeps a
normal `eth0` and can reach peers (dranet injects RDMA *char devices* for IB-only
VFs, not a netdev). The real cause: **the MPI launcher was scheduled on a GB node**,
where dranet's NRI hook is active and disturbs the launcher's OOB callback path.
Pinning the launcher to a clean CPU node (`nodeSelector: agentpool=system`) — as
Anson's setup implicitly does — makes the launch succeed. Workers stay on GB nodes.

So `00-cluster.sh` keeps a **system pool** for the launcher; if it's scaled to 0 or
unhealthy, scale it back up (`az aks nodepool scale ... -n system --node-count 1`).

## Files

| File | Purpose |
|---|---|
| `00–02`, `variables.sh`, `manifests/values-gpu-operator.yaml` | shared with the device-plugin variant |
| `03-nri.sh` | enable NRI in containerd |
| `04-dra-dranet.sh` | install DRA driver + dranet |
| `05-nccl-dra.sh` | mpi-operator + DRA resources + NCCL MPIJob — arg `ib` (default) / `mnnvl` / `both`; prechecks a non-GPU launcher node |
| `manifests/values-dra.yaml` | DRA driver values (driverRoot `/run/nvidia/driver`, ComputeDomains off) |
| `manifests/dranet/` | dranet RBAC + DaemonSet (Anson's fork `ghcr.io/anson627/dranet`) |
| `manifests/device-class.yaml` | `dranet.net` DeviceClass |
| `manifests/resource-claim-template.yaml` | `gpu-nic-aligned` (GPU `0008:06:00.0` + NIC `0101:00:00.0`) |
| `manifests/nccl-dra-mpijob.yaml` | cross-node IB MPIJob (gpu-nic-aligned claim; launcher on system pool) |
| `manifests/nccl-mnnvl-dra.yaml` | cross-node MNNVL: `ComputeDomain` + gpu-only claim + MPIJob |

## DRA vs device plugin

Both deliver working NCCL on GB300; results match:
- **device plugin** (`../deviceplugin`): `nvidia.com/gpu` + direct `/dev/infiniband` (+ manual IMEX); A/B/C = 631 / 88 / 595 GB/s.
- **DRA + dranet** (this): GPU+NIC co-allocated in one claim; IB **88 GB/s** + MNNVL **595 GB/s** (ComputeDomains-automated IMEX). The productiony model — the only rough edges on AKS: launcher must sit on a non-GPU node, GPU↔NIC `pcieRoot` alignment falls back to PCI-address selection (VMBUS), and the CD controller needs the control-plane-affinity patch.
