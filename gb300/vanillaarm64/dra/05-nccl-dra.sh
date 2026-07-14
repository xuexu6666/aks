#!/usr/bin/env bash
# Step 5 — run the NCCL cross-node IB test via DRA. Installs mpi-operator, applies
# the DeviceClass + gpu-nic-aligned ResourceClaimTemplate + MPIJob (which claims a
# GPU + its NIC together), then streams the launcher log.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

if ! kubectl get deploy -n mpi-operator mpi-operator >/dev/null 2>&1; then
  log "Installing kubeflow mpi-operator v0.7.0"
  kubectl apply --server-side -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0"
fi
# mpi-operator controller has no GPU toleration; allow it onto a GB node in case
# the (single) system node is unavailable.
kubectl patch deploy -n mpi-operator mpi-operator --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"sku","value":"gpu","operator":"Equal","effect":"NoSchedule"}]}]' 2>/dev/null || true
kubectl wait --for=condition=available deployment/mpi-operator -n mpi-operator --timeout=300s || true

log "Applying DRA DeviceClass + ResourceClaimTemplate"
kubectl apply -f manifests/device-class.yaml
kubectl apply -f manifests/resource-claim-template.yaml

log "Launching NCCL MPIJob (gpu-nic-aligned claim)"
kubectl delete mpijob nccl-test-dra --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -f manifests/nccl-dra-mpijob.yaml
sleep 20

log "ResourceClaims:"
kubectl get resourceclaims -o wide 2>&1 | grep -v "No resources" || true

log "Waiting for launcher…"
for i in $(seq 1 40); do
  L=$(kubectl get pods -l training.kubeflow.org/job-name=nccl-test-dra,training.kubeflow.org/job-role=launcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "${L}" ] && [ "$(kubectl get pod "${L}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 15
done
kubectl logs -f "${L}" 2>&1 | grep -aE "GB300|via NET|GDRDMA|IBext|DMABUF|busbw|Avg bus|no route|error" || true
ok "DRA NCCL run complete (see log above)."
