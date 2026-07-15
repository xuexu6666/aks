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

log "Waiting for the device plugin to advertise nvidia.com/gpu"
for i in $(seq 1 30); do
  ADV=$(kubectl get nodes -l "agentpool=${NODEPOOL}" -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -vc '^$' || true)
  [ "${ADV:-0}" -ge 1 ] && break
  sleep 15
done
ok "nvidia.com/gpu advertised on ${ADV:-0} node(s)"
kubectl -n "${NAMESPACE}" get pods 2>/dev/null | grep -E "driver|toolkit|device-plugin|dcgm" | head
ok "GPU Operator up: driver + toolkit(file source) + device-plugin + DCGM + exporter."
