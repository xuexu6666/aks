#!/usr/bin/env bash
# Step 1 — create the GB300 node pool on the vanilla arm64 image (BYO driver).
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

az account set --subscription "${SUBSCRIPTION}"

if az aks nodepool show -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" -n "${NODEPOOL}" -o none 2>/dev/null; then
  ok "Node pool '${NODEPOOL}' already exists — skipping create"
else
  log "Creating GB300 node pool '${NODEPOOL}' (${NODE_COUNT}x ${VM_SIZE}) on vanilla arm64 image"
  az aks nodepool add \
    --subscription "${SUBSCRIPTION}" \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name "${NODEPOOL}" \
    --kubernetes-version "${K8S_VERSION}" \
    --node-vm-size "${VM_SIZE}" \
    --node-count "${NODE_COUNT}" \
    --os-sku Ubuntu2404 \
    --gpu-driver None \
    --node-taints "${GPU_TAINT}" \
    --aks-custom-headers "AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,OSImageSubscriptionID=${OS_IMAGE_SUB},OSImageResourceGroup=${OS_IMAGE_RG},OSImageGallery=${OS_IMAGE_GALLERY},OSImageName=${OS_IMAGE_NAME},OSImageVersion=${OS_IMAGE_VERSION}"
  ok "Node pool create submitted"
fi

log "Fetching admin kubeconfig"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing

READY=$(kubectl get nodes -l "agentpool=${NODEPOOL}" --no-headers 2>/dev/null | grep -cw Ready || true)
ok "GB300 nodes Ready: ${READY}"
[ "${READY}" -ge 2 ] || warn "Fewer than 2 Ready nodes — cross-node tests need >=2 (capacity in a pinned availability set can cap this)."
