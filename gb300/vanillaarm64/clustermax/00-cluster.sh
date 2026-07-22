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
  SYS_EXTRA=""
  if [ "${SYSTEM_ON_GB300}" = "1" ]; then
    # DEV-ONLY two-step: GB300 CANNOT be the initial (az aks create) pool — az aks create can't
    # pass --gpu-driver None, so the GB300 image's containerd `nvidia-container-runtime` default
    # has no binary and EVERY pod sandbox fails (azure-cns can't run -> CNI never inits -> nodes
    # stuck NotReady). So bootstrap with a cheap D4s_v5 system pool; 01 then adds the GB300 pool
    # as --mode System --gpu-driver None (which resets containerd to the runc default).
    # Bootstrap the D4s_v5 system pool at SYSTEM_POOL_SIZE (default 3) so the DRA controller +
    # MPI launcher (which must run on a non-GPU node) have an HA home once GB300 joins.
    SYS_SIZE="Standard_D4s_v5"; SYS_CNT="${SYSTEM_POOL_SIZE}"; ZFLAG=""
    warn "SYSTEM_ON_GB300=1 → bootstrap ${SYS_CNT}x D4s_v5 system pool; GB300 system pool added in 01. DEV only, not for CX."
  else
    SYS_SIZE="${SYSTEM_VM_SIZE}"; SYS_CNT="${SYSTEM_POOL_SIZE}"
  fi
  log "Creating AKS cluster '${CLUSTER_NAME}' (system pool: ${SYS_CNT}x ${SYS_SIZE}, k8s ${K8S_VERSION})"
  az aks create \
    --subscription "${SUBSCRIPTION}" \
    -l "${REGION}" \
    -g "${RESOURCE_GROUP}" \
    -n "${CLUSTER_NAME}" \
    --tier standard \
    --kubernetes-version "${K8S_VERSION}" \
    --nodepool-name system \
    --node-vm-size "${SYS_SIZE}" \
    --node-count "${SYS_CNT}" \
    ${ZFLAG} ${SYS_EXTRA} \
    --network-plugin azure \
    --generate-ssh-keys
  ok "Cluster created"
fi

log "Fetching admin kubeconfig"
az aks get-credentials -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --admin --overwrite-existing
kubectl get nodes -o wide 2>&1 | head
