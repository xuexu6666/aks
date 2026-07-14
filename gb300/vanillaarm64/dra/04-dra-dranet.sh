#!/usr/bin/env bash
# Step 4 — install the DRA stack: nvidia-dra-driver-gpu (GPU ResourceSlices) and
# dranet (IB-NIC ResourceSlices). Requires 03-nri.sh (dranet needs NRI).
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
DRA_DRIVER_VERSION="${DRA_DRIVER_VERSION:-25.12.0}"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia >/dev/null 2>&1

log "Installing nvidia-dra-driver-gpu ${DRA_DRIVER_VERSION} (GPU ResourceSlices)"
helm upgrade --install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
  --version "${DRA_DRIVER_VERSION}" --namespace "${NAMESPACE}" \
  -f manifests/values-dra.yaml

log "Deploying dranet (IB-NIC ResourceSlices)"
kubectl apply -f manifests/dranet/
# Anson's daemonset pins nodeSelector agentpool=gpu; retarget to our pool.
kubectl patch ds -n kube-system dranet --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":{\"agentpool\":\"${NODEPOOL}\"}}]" || true

log "Waiting for ResourceSlices…"
for i in $(seq 1 20); do
  g=$(kubectl get resourceslices --field-selector=spec.driver=gpu.nvidia.com --no-headers 2>/dev/null | grep -vc "No resources" || true)
  n=$(kubectl get resourceslices --field-selector=spec.driver=dra.net --no-headers 2>/dev/null | grep -vc "No resources" || true)
  printf '   [%2d] GPU slices=%s  NIC slices=%s\n' "$i" "${g:-0}" "${n:-0}"
  [ "${g:-0}" -ge 1 ] && [ "${n:-0}" -ge 1 ] && break
  sleep 15
done
ok "DRA driver + dranet up. GPU=gpu.nvidia.com, NIC=dra.net ResourceSlices published."
