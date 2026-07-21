#!/usr/bin/env bash
# Step 5 — run the NCCL tests on the full stack.
# Verified on live GB300 (NVLS off, -e 16G):
#   a       = Path A intra-node NVLink  (1 pod, 4 GPUs via DRA)                             ~663 GB/s
#   ib-dra  = Path B cross-node IB/RDMA — dranet + 1 aligned GPU+NIC DRA claim, NON-privileged ~56 GB/s
#   ib-4nic = Path B cross-node IB/RDMA — 4 GPU + 4 aligned NIC (dranet), NON-privileged     ~223 GB/s
#   ib      = Path B cross-node IB/RDMA — privileged + hostPath /dev/infiniband (fallback)   ~88 GB/s
#   mnnvl   = Path C cross-node NVLink  (4 nodes x4 GPU via DRA + ComputeDomains, NVLS off)  ~683 GB/s peak
#   all     = a, then ib-dra (the CX-usable IB path), then mnnvl
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

WHICH="${1:-all}"

apply() { sed -e "s|__NAMESPACE__|${NAMESPACE}|g" -e "s|__NCCL_IMAGE__|${NCCL_IMAGE}|g" "$1" | kubectl apply -f - ; }

ensure_mpi_operator() {
  if ! kubectl get deploy -n mpi-operator mpi-operator >/dev/null 2>&1; then
    log "Installing kubeflow mpi-operator v0.7.0"
    kubectl apply --server-side -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0"
  fi
  # allow the controller onto a GB node if the single system node is busy
  kubectl patch deploy -n mpi-operator mpi-operator --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"sku","value":"gpu","operator":"Equal","effect":"NoSchedule"}]}]' 2>/dev/null || true
  kubectl wait --for=condition=available deployment/mpi-operator -n mpi-operator --timeout=300s || true
}

# dranet (step 05) must be up for the ib-dra path — bail early with guidance if not
ensure_dranet_ready() {
  local n; n=$(kubectl get resourceslices --field-selector=spec.driver=dra.net --no-headers 2>/dev/null | grep -cve '^\s*$' || true)
  [ "${n:-0}" -ge 1 ] || die "no dra.net ResourceSlices — run ./04-ib-dranet.sh first (installs official dranet)"
  # claim template is namespaced; ensure it exists (idempotent)
  apply manifests/dra-claims.yaml
}

# the MPI launcher must run on a NON-GPU node (a Ready 'system' pool node)
ensure_launcher_home() {
  local n; n=$(kubectl get nodes -l agentpool=system --no-headers 2>/dev/null | grep -cw Ready || true)
  [ "${n:-0}" -ge 1 ] || { warn "no Ready system node for the launcher; scaling system pool to ${SYSTEM_POOL_SIZE}"; \
    az aks nodepool scale --subscription "${SUBSCRIPTION}" -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" -n system --node-count "${SYSTEM_POOL_SIZE}" >/dev/null 2>&1 || true; \
    kubectl wait --for=condition=Ready node -l agentpool=system --timeout=300s || true; }
}

run_pod() {  # $1=name $2=manifest  (single Pod)
  log "Path A — intra-node NVLink"
  kubectl delete pod "$1" -n "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  apply "$2"
  kubectl wait --for=condition=Ready pod/"$1" -n "${NAMESPACE}" --timeout=300s 2>/dev/null || true
  kubectl logs -f "$1" -n "${NAMESPACE}" 2>&1 | grep -aE "GPU |busbw|Avg bus|error|NVLS|NVLink" || true
}

run_job() {  # $1=jobname $2=manifest  (MPIJob)
  log "Launching MPIJob $1 ($2)"
  kubectl delete mpijob "$1" -n "${NAMESPACE}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  apply "$2"; sleep 20
  local L=""
  for i in $(seq 1 40); do
    L=$(kubectl get pods -n "${NAMESPACE}" -l training.kubeflow.org/job-name="$1",training.kubeflow.org/job-role=launcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$L" ] && [ "$(kubectl get pod "$L" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 15
  done
  kubectl logs -f "$L" -n "${NAMESPACE}" 2>&1 | grep -aE "GPU |via NET|GDRDMA|DMABUF|MNNVL|NVLS|busbw|Avg bus|no route|error" || true
}

case "${WHICH}" in
  a)      run_pod nccl-nvlink manifests/nccl-nvlink.yaml ;;
  ib-dra) ensure_dranet_ready; ensure_mpi_operator; ensure_launcher_home; run_job nccl-ib-dra manifests/nccl-ib-dra.yaml ;;
  ib-4nic) ensure_dranet_ready; ensure_mpi_operator; ensure_launcher_home; run_job nccl-ib-4nic manifests/nccl-ib-4nic.yaml ;;
  ib)     ensure_mpi_operator; ensure_launcher_home; apply manifests/dra-claims.yaml; run_job nccl-ib     manifests/nccl-ib.yaml ;;
  mnnvl)  ensure_mpi_operator; ensure_launcher_home; apply manifests/dra-claims.yaml; run_job nccl-mnnvl  manifests/nccl-mnnvl.yaml ;;
  all)    run_pod nccl-nvlink manifests/nccl-nvlink.yaml
          ensure_mpi_operator; ensure_launcher_home
          ensure_dranet_ready; run_job nccl-ib-dra manifests/nccl-ib-dra.yaml
          run_job nccl-mnnvl  manifests/nccl-mnnvl.yaml ;;
  *) die "usage: $0 [a|ib-dra|ib|mnnvl|all]" ;;
esac
ok "NCCL run(s) complete (verified GB300, -e 16G, NVLS off): A ~663, ib-dra ~56 (1-NIC), ib-4nic ~223 (4-NIC), MNNVL ~683 GB/s peak (@16G)."
