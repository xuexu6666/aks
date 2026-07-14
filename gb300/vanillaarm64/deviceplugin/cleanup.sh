#!/usr/bin/env bash
# Tear the GPU stack back down (keeps the node pool). Add --nodepool to also
# delete the GB300 pool.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "Removing NCCL jobs + mpi-operator"
kubectl delete pod -n "${NAMESPACE}" nccl-nvlink --ignore-not-found >/dev/null 2>&1 || true
kubectl delete mpijob -n "${NAMESPACE}" nccl-ib nccl-mnnvl --ignore-not-found >/dev/null 2>&1 || true

log "Uninstalling gpu-operator"
helm uninstall gpu-operator -n "${NAMESPACE}" 2>/dev/null || true

log "Stopping IMEX daemons on GB nodes"
az account set --subscription "${SUBSCRIPTION}"
NODE_RG=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "${NODE_RG}" --query "[?contains(name,'${NODEPOOL}')].name | [0]" -o tsv)
for id in $(az vmss list-instances -g "${NODE_RG}" -n "${VMSS}" --query "[].instanceId" -o tsv 2>/dev/null); do
  az vmss run-command invoke --subscription "${SUBSCRIPTION}" -g "${NODE_RG}" -n "${VMSS}" \
    --instance-id "${id}" --command-id RunShellScript \
    --scripts 'pkill -f nvidia-imex || true; echo stopped' --query "value[0].message" -o tsv >/dev/null 2>&1 || true
done

if [ "${1:-}" = "--nodepool" ]; then
  log "Deleting GB300 node pool"
  az aks nodepool delete --subscription "${SUBSCRIPTION}" -g "${RESOURCE_GROUP}" --cluster-name "${CLUSTER_NAME}" -n "${NODEPOOL}"
fi
ok "Cleanup done."
