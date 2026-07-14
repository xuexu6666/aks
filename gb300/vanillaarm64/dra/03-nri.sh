#!/usr/bin/env bash
# Step 3 — enable NRI in containerd on every GB node. dranet is an NRI plugin, so
# NRI must be on. AKS containerd 2.3.2 ships with NRI disabled by default.
# Added ADDITIVELY (a fully-qualified TOML table) so AKS's config is untouched.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

az account set --subscription "${SUBSCRIPTION}"
NODE_RG=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "${NODE_RG}" --query "[?contains(name,'${NODEPOOL}')].name | [0]" -o tsv)

cat > /tmp/_enable_nri.sh <<'REMOTE'
set -e
if ! grep -q 'io.containerd.nri.v1.nri' /etc/containerd/config.toml; then
cat >> /etc/containerd/config.toml <<'EOF'

[plugins."io.containerd.nri.v1.nri"]
  disable = false
  socket_path = "/var/run/nri/nri.sock"
  plugin_path = "/opt/nri/plugins"
  plugin_config_path = "/etc/nri/conf.d"
  plugin_registration_timeout = "5s"
  plugin_request_timeout = "2s"
EOF
mkdir -p /opt/nri/plugins /etc/nri/conf.d
echo "NRI enabled"
else echo "NRI already present"; fi
systemctl restart containerd
sleep 5
echo "containerd: $(systemctl is-active containerd)"
REMOTE

for id in $(az vmss list-instances -g "${NODE_RG}" -n "${VMSS}" --query "[?provisioningState=='Succeeded'].instanceId" -o tsv); do
  log "Enabling NRI on instance ${id}"
  az vmss run-command invoke --subscription "${SUBSCRIPTION}" -g "${NODE_RG}" -n "${VMSS}" \
    --instance-id "${id}" --command-id RunShellScript --scripts @/tmp/_enable_nri.sh \
    --query "value[0].message" -o tsv 2>&1 | grep -iE "NRI|containerd:" | sed 's/^/     /' || true
done
ok "NRI enabled on all active GB nodes."
