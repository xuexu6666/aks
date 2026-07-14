#!/usr/bin/env bash
# Step 3 — bring up IMEX on every GB node (needed for cross-node NVLink / MNNVL).
#
# The nvidia-imex binary ships inside the operator driver container at
# ${DRIVER_ROOT}/usr/bin. It is NOT running and there is no channel device on
# the vanilla image, so we create the channel, write the peer list (all GB node
# InternalIPs), and start the daemon — on each node, over az vmss run-command
# (host-level; the k8s exec tunnel is not involved).
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

az account set --subscription "${SUBSCRIPTION}"
NODE_RG=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "${NODE_RG}" --query "[?contains(name,'${NODEPOOL}')].name | [0]" -o tsv)
[ -n "${VMSS}" ] || die "Could not find the GB300 VMSS in ${NODE_RG}"
log "Node RG=${NODE_RG}  VMSS=${VMSS}"

# Map k8s node -> InternalIP, and node -> VMSS instance id (last hex of node name).
mapfile -t NODES < <(kubectl get nodes -l "agentpool=${NODEPOOL}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
[ "${#NODES[@]}" -ge 2 ] || die "Need >=2 GB nodes for MNNVL; found ${#NODES[@]}"

PEERS=""; IDS=()
for line in "${NODES[@]}"; do
  name=$(awk '{print $1}' <<<"$line"); ip=$(awk '{print $2}' <<<"$line")
  hex="${name##*vmss}"                     # e.g. 00000h
  id=$((16#${hex}))                        # VMSS instance id
  PEERS+="${ip}"$'\n'
  IDS+=("${id}")
  printf '   node %-34s ip=%-12s instance=%s\n' "$name" "$ip" "$id"
done
ok "Peer list (nodes_config.cfg):"; printf '%s' "${PEERS}" | sed 's/^/     /'

SETUP=$(cat <<REMOTE
set -e
BIN=${DRIVER_ROOT}/usr/bin
export LD_LIBRARY_PATH=${DRIVER_LIB}
MAJOR=\$(awk '/nvidia-caps-imex-channels/{print \$1}' /proc/devices)
mkdir -p /dev/nvidia-caps-imex-channels
[ -e /dev/nvidia-caps-imex-channels/channel0 ] || mknod /dev/nvidia-caps-imex-channels/channel0 c \${MAJOR} 0
chmod 0666 /dev/nvidia-caps-imex-channels/channel0
mkdir -p /etc/nvidia-imex
cp -f ${DRIVER_ROOT}/etc/nvidia-imex/config.cfg /etc/nvidia-imex/config.cfg
cat > /etc/nvidia-imex/nodes_config.cfg <<'PEERS'
$(printf '%s' "${PEERS}")
PEERS
pkill -f nvidia-imex || true
sleep 1
\$BIN/nvidia-imex -c /etc/nvidia-imex/config.cfg
sleep 4
\$BIN/nvidia-imex-ctl -N 2>&1 | grep -E 'Node #' || true
REMOTE
)

for id in "${IDS[@]}"; do
  log "Configuring IMEX on instance ${id}"
  az vmss run-command invoke --subscription "${SUBSCRIPTION}" -g "${NODE_RG}" -n "${VMSS}" \
    --instance-id "${id}" --command-id RunShellScript --scripts "${SETUP}" \
    --query "value[0].message" -o tsv 2>&1 | grep -E 'Node #|READY|error' | sed 's/^/     /' || true
done
ok "IMEX started on all GB nodes. Verify a domain is READY with: nvidia-imex-ctl -N"
