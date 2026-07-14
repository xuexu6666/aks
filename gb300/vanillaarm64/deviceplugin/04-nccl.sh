#!/usr/bin/env bash
# Step 4 — run the NCCL test matrix (Path A intra-node NVLink, B cross-node IB,
# C cross-node MNNVL). Usage: ./04-nccl.sh [a|b|c|all]  (default: all)
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
WHICH="${1:-all}"

render() { # manifest -> stdout with placeholders substituted
  sed -e "s#__NCCL_IMAGE__#${NCCL_IMAGE}#g" \
      -e "s#__DRIVER_ROOT__#${DRIVER_ROOT}#g" \
      -e "s#__DRIVER_LIB__#${DRIVER_LIB}#g" \
      -e "s#__NAMESPACE__#${NAMESPACE}#g" "$1"
}

ensure_mpi_operator() {
  if ! kubectl get deployment mpi-operator -n mpi-operator >/dev/null 2>&1; then
    log "Installing kubeflow mpi-operator v0.7.0"
    kubectl apply --server-side -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0"
    kubectl wait --for=condition=available deployment/mpi-operator -n mpi-operator --timeout=300s
  fi
}

run_pod() { # Path A
  log "Path A — intra-node NVLink (4 GPU)"
  kubectl delete pod -n "${NAMESPACE}" nccl-nvlink --ignore-not-found >/dev/null 2>&1 || true
  render manifests/nccl-nvlink.yaml | kubectl apply -f -
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nccl-nvlink -n "${NAMESPACE}" --timeout=600s \
    || kubectl wait --for=jsonpath='{.status.phase}'=Running pod/nccl-nvlink -n "${NAMESPACE}" --timeout=120s || true
  kubectl logs -n "${NAMESPACE}" nccl-nvlink | grep -E "GB300|busbw|Avg bus" | tail -20
}

run_mpijob() { # $1=name $2=manifest
  local name="$1" mf="$2"
  log "Running MPIJob ${name}"
  ensure_mpi_operator
  kubectl delete mpijob -n "${NAMESPACE}" "${name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  render "${mf}" | kubectl apply -f -
  log "Waiting for launcher…"
  for i in $(seq 1 40); do
    L=$(kubectl get pods -n "${NAMESPACE}" -l training.kubeflow.org/job-name="${name}",training.kubeflow.org/job-role=launcher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${L}" ] && [ "$(kubectl get pod -n "${NAMESPACE}" "${L}" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
    sleep 15
  done
  kubectl logs -f -n "${NAMESPACE}" "${L}" 2>&1 | grep -E "GB300|via NET|GDRDMA|MNNVL|NVLS|busbw|Avg bus|error|Cuda failure" || true
}

case "${WHICH}" in
  a|A)   run_pod ;;
  b|B)   run_mpijob nccl-ib    manifests/nccl-ib.yaml ;;
  c|C)   run_mpijob nccl-mnnvl manifests/nccl-mnnvl.yaml ;;
  all)   run_pod; run_mpijob nccl-ib manifests/nccl-ib.yaml; run_mpijob nccl-mnnvl manifests/nccl-mnnvl.yaml ;;
  *) die "usage: $0 [a|b|c|all]" ;;
esac
ok "NCCL run(s) complete."
