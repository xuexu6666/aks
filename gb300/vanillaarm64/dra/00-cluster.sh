#!/usr/bin/env bash
# Step 0 — create the resource group + AKS cluster (system pool only).
# The GPU node pool is added separately by 01-nodepool.sh. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

az account set --subscription "${SUBSCRIPTION}"

if az group show -n "${RESOURCE_GROUP}" -o none 2>/dev/null; then
  ok "Resource group '${RESOURCE_GROUP}' already exists"
else
  log "Creating resource group '${RESOURCE_GROUP}' in '${REGION}'"
  az group create -l "${REGION}" -n "${RESOURCE_GROUP}" -o none
fi

if az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" -o none 2>/dev/null; then
  ok "AKS cluster '${CLUSTER_NAME}' already exists"
else
  log "Creating AKS cluster '${CLUSTER_NAME}' (system pool: ${SYSTEM_POOL_SIZE}x ${SYSTEM_VM_SIZE}, k8s ${K8S_VERSION})"
  az aks create \
    --subscription "${SUBSCRIPTION}" \
    -l "${REGION}" \
    -g "${RESOURCE_GROUP}" \
    -n "${CLUSTER_NAME}" \
    --tier standard \
    --kubernetes-version "${K8S_VERSION}" \
    --nodepool-name system \
    --node-vm-size "${SYSTEM_VM_SIZE}" \
    --node-count "${SYSTEM_POOL_SIZE}" \
    --network-plugin azure \
    --generate-ssh-keys
  ok "Cluster created"
fi

log "Fetching admin kubeconfig"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing
kubectl get nodes -o wide 2>&1 | head
