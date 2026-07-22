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
  # Only pass --zones when SYSTEM_ZONES is set (zone support varies by region/sub).
  ZFLAG=""; [ -n "${SYSTEM_ZONES}" ] && ZFLAG="--zones ${SYSTEM_ZONES}"
  # DEV-ONLY: system pool on GB300 needs the vanilla-arm64 custom image (same headers as
  # the GPU pool in 01) and no zone pin (GB300 lives in its own availability set).
  if [ "${SYSTEM_ON_GB300}" = "1" ]; then
    SYS_SIZE="${VM_SIZE}"; ZFLAG=""
    # Same vanilla-arm64 custom image as the GPU pool in 01. NOTE: `az aks create` does NOT
    # accept --gpu-driver (that flag is nodepool-add only, used in 01); the vanilla image is
    # BYO-driver and the GPU operator (02) installs the driver, so it isn't needed here.
    SYS_EXTRA="--os-sku Ubuntu2404 --aks-custom-headers AKSHTTPCustomFeatures=Microsoft.ContainerService/UseCustomizedOSImage,OSImageSubscriptionID=${OS_IMAGE_SUB},OSImageResourceGroup=${OS_IMAGE_RG},OSImageGallery=${OS_IMAGE_GALLERY},OSImageName=${OS_IMAGE_NAME},OSImageVersion=${OS_IMAGE_VERSION}"
    warn "SYSTEM_ON_GB300=1 → system pool on ${SYS_SIZE} (vanilla arm64 custom image). DEV workaround, not for CX."
  else
    SYS_SIZE="${SYSTEM_VM_SIZE}"; SYS_EXTRA=""
  fi
  log "Creating AKS cluster '${CLUSTER_NAME}' (system pool: ${SYSTEM_POOL_SIZE}x ${SYS_SIZE}, k8s ${K8S_VERSION})"
  az aks create \
    --subscription "${SUBSCRIPTION}" \
    -l "${REGION}" \
    -g "${RESOURCE_GROUP}" \
    -n "${CLUSTER_NAME}" \
    --tier standard \
    --kubernetes-version "${K8S_VERSION}" \
    --nodepool-name system \
    --node-vm-size "${SYS_SIZE}" \
    --node-count "${SYSTEM_POOL_SIZE}" \
    ${ZFLAG} ${SYS_EXTRA} \
    --network-plugin azure \
    --generate-ssh-keys
  ok "Cluster created"
fi

log "Fetching admin kubeconfig"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing
kubectl get nodes -o wide 2>&1 | head
