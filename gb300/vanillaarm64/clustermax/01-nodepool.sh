#!/usr/bin/env bash
# Step 1 — create the GB300 node pool on the vanilla arm64 image (BYO driver).
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

az account set --subscription "${SUBSCRIPTION}"

if az aks nodepool show -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" -n "${NODEPOOL}" -o none 2>/dev/null; then
  ok "Node pool '${NODEPOOL}' already exists — skipping create"
else
  # DEV-ONLY (SYSTEM_ON_GB300=1): make the GB300 pool the SYSTEM pool — a system pool can't
  # carry the sku=gpu taint (it must run critical addons), so drop it and set --mode System.
  # Default (CX): --mode User + sku=gpu taint so GPU nodes are dedicated to GPU workloads.
  if [ "${SYSTEM_ON_GB300}" = "1" ]; then
    POOL_FLAGS="--mode System"
  else
    POOL_FLAGS="--mode User --node-taints ${GPU_TAINT}"
  fi
  log "Creating GB300 node pool '${NODEPOOL}' (${NODE_COUNT}x ${VM_SIZE}, ${POOL_FLAGS}) on vanilla arm64 image"
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
    ${POOL_FLAGS} \
    --aks-custom-headers "AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,OSImageSubscriptionID=${OS_IMAGE_SUB},OSImageResourceGroup=${OS_IMAGE_RG},OSImageGallery=${OS_IMAGE_GALLERY},OSImageName=${OS_IMAGE_NAME},OSImageVersion=${OS_IMAGE_VERSION}" \
    2> >(tee /tmp/gb300-nodepool-err.log >&2) \
    || {
      # Only treat a capacity/allocation shortfall as benign; surface everything else.
      if grep -qiE "capacity|allocat|SkuNotAvailable|zonal|OverconstrainedAllocation|quota" /tmp/gb300-nodepool-err.log; then
        warn "nodepool add: GB300 capacity/allocation shortfall (expected for a pinned rack). Continuing; the readiness check below decides if we have enough."
      else
        die "nodepool add failed for a NON-capacity reason (see error above) — e.g. bad custom header, unregistered SKU/feature, or auth."
      fi
    }
  ok "Node pool create submitted"
fi

log "Fetching admin kubeconfig"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing

READY=$(kubectl get nodes -l "agentpool=${NODEPOOL}" --no-headers 2>/dev/null | grep -cw Ready || true)
ok "GB300 nodes Ready: ${READY}"
[ "${READY}" -ge 2 ] || warn "Fewer than 2 Ready nodes — cross-node tests need >=2 (capacity in a pinned availability set can cap this)."
