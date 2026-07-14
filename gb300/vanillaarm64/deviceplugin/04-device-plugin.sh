#!/usr/bin/env bash
# Step 4 — deploy the device plugins: nvidia.com/gpu (always) and, for cross-node
# IB, rdma/shared_ib. Requires 03-nvidia-runtime.sh (nvidia runtime + RuntimeClass).
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
# RDMA shared device plugin is OFF by default: it requires uverbs+umad+rdma_cm per
# device, but GB300 IB VFs expose NO umad (MAD) device, so it advertises 0. Cross-node
# IB (Path B) instead injects /dev/infiniband directly (see nccl-ib.yaml). Set
# WITH_RDMA=true only on SKUs whose VFs expose umad.
WITH_RDMA="${WITH_RDMA:-false}"

log "Deploying nvidia-device-plugin (runtimeClassName: nvidia)"
kubectl apply -f manifests/nvidia-device-plugin.yaml

if [ "${WITH_RDMA}" = "true" ]; then
  log "Deploying rdma-shared-dev-plugin (rdma/shared_ib)"
  kubectl apply -f manifests/rdma-shared-dev-plugin.yaml
fi

log "Waiting for nvidia.com/gpu to be advertised…"
for i in $(seq 1 20); do
  n=$(kubectl get nodes -l "agentpool=${NODEPOOL}" -o jsonpath='{range .items[*]}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^[1-9]' || true)
  printf '   [%2d] nodes advertising nvidia.com/gpu: %s\n' "$i" "${n:-0}"
  [ "${n:-0}" -ge 1 ] && break
  sleep 15
done

log "Capacity on GB nodes:"
kubectl get nodes -l "agentpool=${NODEPOOL}" \
  -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu,IB:.status.capacity.rdma/shared_ib' --no-headers
ok "Device plugin(s) up. Pods can now request nvidia.com/gpu (+ rdma/shared_ib) with runtimeClassName: nvidia."
