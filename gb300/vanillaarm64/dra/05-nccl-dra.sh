#!/usr/bin/env bash
# Step 5 — run the NCCL cross-node IB test via DRA. Installs mpi-operator, applies
# the DeviceClass + gpu-nic-aligned ResourceClaimTemplate + MPIJob (which claims a
# GPU + its NIC together), then streams the launcher log.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

# --- PRECHECK: the MPI launcher must run on a NON-GPU node -------------------
# dranet's NRI hook is active on GB nodes and breaks the launcher's OpenMPI OOB
# callback ("ORTE ... no route"). The MPIJob pins the launcher to agentpool=system,
# so a Ready system node must exist.
SYS_READY=$(kubectl get nodes -l agentpool=system --no-headers 2>/dev/null | grep -cw Ready || true)
if [ "${SYS_READY:-0}" -lt 1 ]; then
  warn "No Ready 'system' (non-GPU) node — the launcher can't schedule there."
  warn "Scaling the system pool up so the launcher has a home…"
  az aks nodepool scale --subscription "${SUBSCRIPTION}" -g "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" -n system --node-count 1 2>&1 | tail -1 || \
    die "Could not ensure a system node. Add a non-GPU pool for the launcher and retry."
  kubectl wait --for=condition=Ready node -l agentpool=system --timeout=300s || true
fi
ok "system (non-GPU) nodes Ready: $(kubectl get nodes -l agentpool=system --no-headers 2>/dev/null | grep -cw Ready)"

if ! kubectl get deploy -n mpi-operator mpi-operator >/dev/null 2>&1; then
  log "Installing kubeflow mpi-operator v0.7.0"
  kubectl apply --server-side -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0"
fi
# mpi-operator controller has no GPU toleration; allow it onto a GB node in case
# the (single) system node is unavailable.
kubectl patch deploy -n mpi-operator mpi-operator --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"sku","value":"gpu","operator":"Equal","effect":"NoSchedule"}]}]' 2>/dev/null || true
kubectl wait --for=condition=available deployment/mpi-operator -n mpi-operator --timeout=300s || true

# which test: ib (cross-node IB, default) | mnnvl (cross-node NVLink) | both
WHICH="${1:-ib}"

run_job() { # $1=jobname  $2=manifest
  local job="$1" mf="$2"
  log "Launching MPIJob ${job} (${mf})"
  kubectl delete mpijob "${job}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -f "${mf}"
  sleep 20
  kubectl get resourceclaims -o wide 2>&1 | grep -v "No resources" | grep "${job}" || true
  local L=""
  for i in $(seq 1 40); do
    L=$(kubectl get pods -l training.kubeflow.org/job-name="${job}",training.kubeflow.org/job-role=launcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${L}" ] && [ "$(kubectl get pod "${L}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 15
  done
  kubectl logs -f "${L}" 2>&1 | grep -aE "GB300|via NET|GDRDMA|DMABUF|MNNVL|NVLS|busbw|Avg bus|no route|error" || true
}

log "Applying DRA DeviceClass + gpu-nic-aligned ResourceClaimTemplate"
kubectl apply -f manifests/device-class.yaml
kubectl apply -f manifests/resource-claim-template.yaml

case "${WHICH}" in
  ib)    run_job nccl-test-dra  manifests/nccl-dra-mpijob.yaml ;;
  mnnvl) run_job nccl-mnnvl-dra manifests/nccl-mnnvl-dra.yaml ;;
  both)  run_job nccl-test-dra  manifests/nccl-dra-mpijob.yaml
         run_job nccl-mnnvl-dra manifests/nccl-mnnvl-dra.yaml ;;
  *) die "usage: $0 [ib|mnnvl|both]" ;;
esac
ok "DRA NCCL run(s) complete (see log above). IB=~88 GB/s, MNNVL=~595 GB/s."
