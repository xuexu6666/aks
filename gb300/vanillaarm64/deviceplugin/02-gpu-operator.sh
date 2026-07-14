#!/usr/bin/env bash
# Step 2 — install the GPU Operator (driver only) and confirm the driver builds.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "Adding NVIDIA helm repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia >/dev/null 2>&1

log "Installing gpu-operator ${GPU_OPERATOR_VERSION} (driver only, toolkit OFF)"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version "${GPU_OPERATOR_VERSION}" \
  --create-namespace --namespace "${NAMESPACE}" \
  -f manifests/values-gpu-operator.yaml

log "Waiting for the driver DaemonSet to build + load (open R580 DKMS vs linux-azure-nvidia arm64)…"
# Driver pods appear only after NFD labels the GB nodes (feature.node.kubernetes.io/pci-10de.present).
for i in $(seq 1 60); do
  total=$(kubectl get pods -n "${NAMESPACE}" -l app=nvidia-driver-daemonset --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get pods -n "${NAMESPACE}" -l app=nvidia-driver-daemonset --no-headers 2>/dev/null | awk '$2=="1/1"' | wc -l | tr -d ' ')
  printf '   [%2d] driver pods ready %s/%s\n' "$i" "${ready:-0}" "${total:-0}"
  if [ "${total:-0}" -gt 0 ] && [ "${ready:-0}" -eq "${total:-0}" ]; then break; fi
  sleep 15
done

DP=$(kubectl get pods -n "${NAMESPACE}" -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "${DP}" ] || die "No driver pod found — check NFD labelled the GB nodes."

log "Verifying GPUs via nvidia-smi in the driver pod"
kubectl exec -n "${NAMESPACE}" "${DP}" -c nvidia-driver-ctr -- nvidia-smi -L \
  || die "nvidia-smi failed — driver did not build/load. This is the Experiment-1 gate."
ok "Driver up: open R580 built against linux-azure-nvidia arm64, GPUs enumerated."
warn "Note: no nvidia.com/gpu resource is advertised — GPU injection is via direct driver-mount (see nccl-*.yaml), not the k8s device plugin."
