#!/usr/bin/env bash
# Step 2 — install the FULL NVIDIA GPU Operator stack on the GB300 pool:
#   driver (open R580) + container-toolkit + device plugin + DCGM + dcgm-exporter.
#
# The AKS-critical bit is in manifests/values-gpu-operator.yaml:
#   toolkit.env RUNTIME_CONFIG_SOURCE=file  — without it the toolkit writes a
#   containerd v4 drop-in that AKS's v2 root rejects (containerd crash-loop ->
#   nodes NotReady). With it, containerd stays healthy and the nvidia runtime
#   is registered. See the values file for the full RCA.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update nvidia >/dev/null 2>&1

log "Installing GPU Operator ${GPU_OPERATOR_VERSION} (driver + toolkit + device-plugin + DCGM + exporter)"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version "${GPU_OPERATOR_VERSION}" \
  --create-namespace -n "${NAMESPACE}" \
  -f manifests/values-gpu-operator.yaml

log "Waiting for the open R580 driver to DKMS-build (~5 min) and the toolkit to configure containerd…"
kubectl -n "${NAMESPACE}" rollout status ds/nvidia-driver-daemonset --timeout=900s 2>/dev/null || \
  warn "driver daemonset not ready yet — check 'kubectl -n ${NAMESPACE} get pods'"

# Guard: the whole point of RUNTIME_CONFIG_SOURCE=file is that nodes STAY Ready
# after the toolkit lands. If any GPU node flips NotReady, the toolkit rewrote a
# bad drop-in — abort loudly rather than silently limp.
NOTREADY=$(kubectl get nodes -l "agentpool=${NODEPOOL}" --no-headers 2>/dev/null | grep -cw NotReady || true)
[ "${NOTREADY:-0}" -eq 0 ] || die "${NOTREADY} GB300 node(s) went NotReady after the toolkit — check the containerd drop-in version on the node (should be 2, not 4)."

# Device plugin is OFF (values-gpu-operator.yaml) — GPUs are published as
# gpu.nvidia.com DRA ResourceSlices by the DRA driver in step 03, NOT as
# nvidia.com/gpu. So nothing to wait for here beyond the driver + toolkit.
kubectl -n "${NAMESPACE}" get pods 2>/dev/null | grep -E "driver|toolkit|dcgm" | head
ok "GPU Operator up: driver + toolkit(file source) + DCGM + exporter (device plugin OFF; GPUs via DRA — step 03)."
