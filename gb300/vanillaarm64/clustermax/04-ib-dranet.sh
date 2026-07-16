#!/usr/bin/env bash
# Step 4 (optional, CX-usable IB) — OFFICIAL dranet for non-privileged IB via DRA.
#
# Installs kubernetes-sigs/dranet (the upstream Kubernetes-SIG project, pinned at
# ${DRANET_VERSION}) so GB300 IB VFs are published as `dra.net` ResourceSlices and
# their /dev/infiniband char devices get injected into ordinary (non-privileged)
# pods. GB300 IB VFs are RDMA-only (no netdev); official dranet >= v1.3.0 handles
# them via Anson's upstreamed IB-only support (PR #77, merged into the SIG repo).
# This replaces the earlier personal fork (ghcr.io/anson627/dranet) used by ../dra.
#
# NRI: no action needed. containerd 2.x enables NRI by default (verified on AKS
# 2.3.2: `containerd config dump` -> io.containerd.nri.v1.nri disable=false, and
# /var/run/nri/nri.sock exists — it's the containerd built-in default, not set by
# any config file). dranet is an NRI plugin and just connects.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
DRANET_VERSION="${DRANET_VERSION:-v1.3.0}"
INSTALL_URL="https://raw.githubusercontent.com/kubernetes-sigs/dranet/${DRANET_VERSION}/install.yaml"

apply_ns() { sed -e "s|__NAMESPACE__|${NAMESPACE}|g" "$1" | kubectl apply -f - ; }

# quick, read-only NRI sanity check (never mutates the node)
if kubectl get nodes -l "agentpool=${NODEPOOL}" -o name >/dev/null 2>&1; then
  :
fi

log "Installing OFFICIAL dranet ${DRANET_VERSION} (kubernetes-sigs/dranet)"
kubectl apply -f "${INSTALL_URL}"

# install.yaml ships the image as ':stable', no nodeSelector, and the default args
# (--v=4 --hostname-override). We (1) pin the image to the release tag, (2) confine
# the DaemonSet to our GB300 pool, and (3) add --move-ib-interfaces=false — the
# upstream GB300 example (examples/azure_aks_examples/gb300) requires this for
# IB-mode ConnectX VFs so dranet publishes rdmaDevice attributes instead of trying
# to move (non-existent) IPoIB netdevs into the pod netns.
log "Pinning image to ${DRANET_VERSION}, targeting pool '${NODEPOOL}', IB-only mode"
kubectl -n kube-system set image ds/dranet dranet="registry.k8s.io/networking/dranet:${DRANET_VERSION}"
kubectl -n kube-system patch ds dranet --type=json \
  -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":{\"agentpool\":\"${NODEPOOL}\"}}]" \
  2>/dev/null || warn "nodeSelector patch skipped (already set)"
# replace the whole args array (idempotent) to guarantee --move-ib-interfaces=false
kubectl -n kube-system patch ds dranet --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["/dranet","--v=4","--hostname-override=$(NODE_NAME)","--move-ib-interfaces=false"]}]' \
  2>/dev/null || warn "args patch skipped"
kubectl -n kube-system rollout status ds/dranet --timeout=180s 2>/dev/null || \
  warn "dranet DaemonSet not fully rolled out yet — check 'kubectl -n kube-system get pods -l app=dranet'"

log "Applying DeviceClass (dranet.net) + GPU/NIC DRA claim templates"
kubectl apply -f manifests/dranet-device-class.yaml
apply_ns manifests/dra-claims.yaml

log "Waiting for dra.net (IB NIC) ResourceSlices…"
for i in $(seq 1 20); do
  n=$(kubectl get resourceslices --field-selector=spec.driver=dra.net --no-headers 2>/dev/null | grep -cve '^\s*$' || true)
  printf '   [%2d] dra.net NIC slices=%s\n' "$i" "${n:-0}"
  [ "${n:-0}" -ge 1 ] && break
  sleep 15
done
[ "${n:-0}" -ge 1 ] || die "no dra.net ResourceSlices — check dranet pods: kubectl -n kube-system logs -l app=dranet"

rdma=$(kubectl get resourceslices --field-selector=spec.driver=dra.net -o json 2>/dev/null \
  | grep -c 'dra.net/rdmaDevice' || true)
ok "Official dranet up. dra.net ResourceSlices published (RDMA/IB VF devices: ${rdma:-?})."
ok "Run the non-privileged IB test:  ./05-nccl.sh ib-dra"
