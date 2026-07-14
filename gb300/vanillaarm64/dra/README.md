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

## ⚠️ Known gap: cross-node NCCL launch

The 2-node NCCL MPIJob currently **fails at the MPI launch**, not the GPU/NIC
allocation:

```
ORTE does not know how to route a message to ... nccl-test-dra-worker-1
  ... lack of common network interfaces and/or no route found between them
```

This is the **dranet-on-AKS networking gap** documented in Anson's design
(`DESIGN.md`: Phase-4 NRI hooks / network-namespace handling for IB-only devices
are **not fully implemented**; NIC `pcieRoot` isn't resolvable on Azure VMBUS, so
the GPU↔NIC alignment falls back to PCI-address selection). dranet's NRI injection
disturbs the worker pod's OOB path so OpenMPI's `orted` can't route between
launcher and workers. Tried `routed=direct` and pinning `oob_tcp_if_include` to
`eth0` / the pod CIDR — the routing error persists.

**Status:** allocation ✅, NCCL cross-node ❌ (dranet network gap). For a *working*
NCCL cross-node result on this hardware, use the **device-plugin variant**
(`../deviceplugin`), which hits ~88 GB/s (IB) / ~595 GB/s (MNNVL) via direct
`/dev/infiniband` + IMEX. Closing this gap needs dranet's IB-only NRI network
hooks completed upstream/in the fork.

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
| `manifests/nccl-dra-mpijob.yaml` | NCCL MPIJob using the aligned claim (sku=gpu tolerations + MPI OOB flags added) |

## DRA vs device plugin

- **device plugin** (`../deviceplugin`): `nvidia.com/gpu` + direct `/dev/infiniband`; simplest; NCCL A/B/C validated.
- **DRA + dranet** (this): GPU + NIC co-allocated & (intended) NUMA-aligned in one claim; the productiony model — but the AKS IB-only network path isn't complete yet.
