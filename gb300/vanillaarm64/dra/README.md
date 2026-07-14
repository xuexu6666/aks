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

## ✅ Cross-node NCCL — WORKING (~88 GB/s)

2-node `all_reduce_perf` via the DRA `gpu-nic-aligned` claim:

```
NET/IB: Data Direct DMA Interface detected for mlx5_0..3
GPU Direct RDMA (DMABUF) enabled
# Avg bus bandwidth : 88.16 GB/s   (exit 0)
```

Same GDR-via-dmabuf transport as the device-plugin variant — but here the GPU **and**
its IB NIC are co-allocated by DRA (the claim shows `allocated,reserved`) and dranet
injects the NIC's RDMA devices into the worker.

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
| `05-nccl-dra.sh` | mpi-operator + DRA resources + NCCL MPIJob |
| `manifests/values-dra.yaml` | DRA driver values (driverRoot `/run/nvidia/driver`, ComputeDomains off) |
| `manifests/dranet/` | dranet RBAC + DaemonSet (Anson's fork `ghcr.io/anson627/dranet`) |
| `manifests/device-class.yaml` | `dranet.net` DeviceClass |
| `manifests/resource-claim-template.yaml` | `gpu-nic-aligned` (GPU `0008:06:00.0` + NIC `0101:00:00.0`) |
| `manifests/nccl-dra-mpijob.yaml` | NCCL MPIJob using the aligned claim (launcher pinned to system pool) |

## DRA vs device plugin

- **device plugin** (`../deviceplugin`): `nvidia.com/gpu` + direct `/dev/infiniband`; simplest; NCCL A/B/C validated (631 / 88 / 595 GB/s).
- **DRA + dranet** (this): GPU + NIC co-allocated in one claim; cross-node IB NCCL validated at **~88 GB/s** (launcher on a non-GPU node). The productiony model — GPU↔NIC `pcieRoot` NUMA-alignment still falls back to PCI-address selection on AKS (VMBUS), and MNNVL would need ComputeDomains enabled.
