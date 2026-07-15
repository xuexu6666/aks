#!/usr/bin/env bash
# Step 3 — install the NVIDIA DRA driver for ComputeDomains (cross-node NVLink / IMEX).
#
# The device plugin (step 2) already owns GPU allocation, so the DRA driver here is
# ComputeDomains-ONLY: gpuResourcesEnabledOverride=false (see manifests/values-dra.yaml).
# This is what lets the two coexist without double-allocating GPUs. DRA is GA on
# k8s >= 1.34 (default-on); AKS 1.35.5 has it. NRI is already enabled on AKS
# containerd 2.3.2, so nothing extra to flip there.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia >/dev/null 2>&1

log "Installing nvidia-dra-driver-gpu ${DRA_DRIVER_VERSION} (ComputeDomains only)"
helm upgrade --install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
  --version "${DRA_DRIVER_VERSION}" --namespace "${NAMESPACE}" \
  -f manifests/values-dra.yaml

# The ComputeDomains controller ships with a hardcoded affinity for
# node-role.kubernetes.io/control-plane nodes, which DON'T exist on AKS (managed
# control plane) -> it stays Pending and never creates ComputeDomain channels.
# Retarget it to a system (non-GPU) node.
log "Retargeting ComputeDomains controller off control-plane affinity (AKS has none)"
for i in $(seq 1 12); do
  kubectl get deploy -n "${NAMESPACE}" nvidia-dra-driver-gpu-controller >/dev/null 2>&1 && break
  sleep 5
done
kubectl patch deploy -n "${NAMESPACE}" nvidia-dra-driver-gpu-controller --type=json -p='[
  {"op":"remove","path":"/spec/template/spec/affinity"},
  {"op":"add","path":"/spec/template/spec/nodeSelector","value":{"agentpool":"system"}}
]' 2>/dev/null || warn "controller patch skipped (already patched or absent)"

kubectl -n "${NAMESPACE}" rollout status deploy/nvidia-dra-driver-gpu-controller --timeout=180s 2>/dev/null || \
  warn "CD controller not ready yet — check 'kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=nvidia-dra-driver-gpu'"
ok "DRA driver up (ComputeDomains). GPUs stay on the device plugin; DRA provides IMEX channels for MNNVL."
