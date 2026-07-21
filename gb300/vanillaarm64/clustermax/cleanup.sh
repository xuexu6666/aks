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
  kubectl delete -f "https://raw.githubusercontent.com/kubernetes-sigs/dranet/${DRANET_VERSION:-v1.3.0}/install.yaml" 2>/dev/null || true
  kubectl delete deviceclass dranet.net 2>/dev/null || true
  kubectl delete -k "https://github.com/kubeflow/mpi-operator/manifests/overlays/standalone?ref=v0.7.0" 2>/dev/null || true
  # also clear DRA leftovers so a re-run doesn't collide on stale claims/domains
  kubectl delete -f manifests/dra-claims.yaml -n "${NAMESPACE}" 2>/dev/null || true
  kubectl delete computedomain --all -n "${NAMESPACE}" 2>/dev/null || true
  kubectl delete mpijob --all -n "${NAMESPACE}" 2>/dev/null || true
  ok "charts removed (cluster + pool kept)"
else
  # Default to a WAITED delete: --no-wait can silently fail server-side and leave an
  # 18-node GB300 rack billing. Set NO_WAIT=1 only if you will verify deletion yourself.
  log "Deleting resource group '${RESOURCE_GROUP}' (cluster + GB300 pool)"
  # Safety rails: this deletes the WHOLE RG. Never touch a clustermax* RG, and require an
  # explicit confirmation (re-type the RG name, or set FORCE=1 for non-interactive runs).
  case "${RESOURCE_GROUP}" in
    clustermax*) die "refusing to delete an RG named '${RESOURCE_GROUP}' — clustermax* RGs are off-limits" ;;
  esac
  if [ "${FORCE:-0}" != "1" ]; then
    printf '  !! About to DELETE resource group "%s" (sub %s): cluster "%s" + any GB300 pool.\n' \
      "${RESOURCE_GROUP}" "${SUBSCRIPTION}" "${CLUSTER_NAME}"
    read -r -p '  Re-type the resource group name to confirm: ' _confirm
    [ "${_confirm}" = "${RESOURCE_GROUP}" ] || die "confirmation did not match '${RESOURCE_GROUP}' — aborting"
  fi
  az group delete -n "${RESOURCE_GROUP}" --yes ${NO_WAIT:+--no-wait}
  if [ -z "${NO_WAIT:-}" ]; then
    az group show -n "${RESOURCE_GROUP}" -o none 2>/dev/null \
      && die "Resource group still exists after delete — verify manually, a GB300 rack may still be billing" \
      || ok "resource group deleted"
  else
    warn "delete submitted (--no-wait); verify the RG is actually gone so the rack does not leak"
  fi
fi
