#!/usr/bin/env bash
# Tear down everything this variant created. Deletes the whole resource group
# (cluster + GB300 pool). Set KEEP_RG=1 to only remove the in-cluster charts.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
az account set --subscription "${SUBSCRIPTION}"

if [ "${KEEP_RG:-0}" = "1" ]; then
  log "Removing in-cluster charts only (KEEP_RG=1)"
  az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing 2>/dev/null || true
  helm uninstall nvidia-dra-driver-gpu -n "${NAMESPACE}" 2>/dev/null || true
  helm uninstall gpu-operator -n "${NAMESPACE}" 2>/dev/null || true
  kubectl delete -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0" 2>/dev/null || true
  ok "charts removed (cluster + pool kept)"
else
  log "Deleting resource group '${RESOURCE_GROUP}' (cluster + GB300 pool)"
  az group delete -n "${RESOURCE_GROUP}" --yes --no-wait
  ok "delete submitted"
fi
