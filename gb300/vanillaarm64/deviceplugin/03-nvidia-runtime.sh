#!/usr/bin/env bash
# Step 3 — wire the nvidia container runtime into AKS containerd the *AKS-native*
# way, so the device plugin + normal `nvidia.com/gpu` requests work.
#
# WHY NOT the GPU Operator toolkit: `nvidia-ctk runtime configure` REWRITES AKS's
# /etc/containerd/config.toml (reformats it + prepends an imports= line) and
# crash-loops containerd 2.3.2 -> nodes NotReady. Instead we:
#   1. install ONLY the toolkit binaries to /usr/local/nvidia/toolkit
#      (no containerd config step), and
#   2. ADDITIVELY append a fully-qualified `nvidia` runtime table to AKS's
#      existing config.toml (TOML tables can be defined out of order) — this
#      leaves every AKS-specific setting untouched and does NOT break containerd.
# The runtime runs in `legacy` mode: its prestart hook calls nvidia-container-cli
# to inject the driver libs + device nodes from driverRoot=/run/nvidia/driver.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh
TOOLKIT_IMAGE="${TOOLKIT_IMAGE:-nvcr.io/nvidia/k8s/container-toolkit:v1.18.1}"

# --- ensure the nvidia RuntimeClass exists ----------------------------------
kubectl apply -f manifests/runtimeclass-nvidia.yaml

# --- 1) install toolkit binaries to /usr/local/nvidia/toolkit on every GB node
log "Installing nvidia container-toolkit BINARIES (no containerd config)"
sed "s#__TOOLKIT_IMAGE__#${TOOLKIT_IMAGE}#g; s#__DRIVER_ROOT__#${DRIVER_ROOT}#g" \
  manifests/toolkit-install-daemonset.yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" rollout status ds/nvidia-toolkit-install --timeout=300s || true
sleep 5

# --- 2) additively wire containerd + set legacy mode, per node (host-level) ---
az account set --subscription "${SUBSCRIPTION}"
NODE_RG=$(az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "${NODE_RG}" --query "[?contains(name,'${NODEPOOL}')].name | [0]" -o tsv)

cat > /tmp/_wire_containerd.sh <<'REMOTE'
set -e
CFG=/usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml
# legacy mode = classic prestart-hook lib injection (AKS fully-managed style)
sed -i 's/mode = "cdi"/mode = "legacy"/' "$CFG" 2>/dev/null || true
# make sure the CLI points at the operator driver root
grep -q 'root = "/run/nvidia/driver"' "$CFG" || echo "WARN: driver root not set in $CFG"
# additively add the nvidia runtime to AKS containerd config (idempotent)
if ! grep -q 'runtimes.nvidia\]' /etc/containerd/config.toml; then
cat >> /etc/containerd/config.toml <<'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
  BinaryName = "/usr/local/nvidia/toolkit/nvidia-container-runtime"
EOF
fi
systemctl restart containerd
sleep 5
echo "containerd: $(systemctl is-active containerd)"
REMOTE

for id in $(az vmss list-instances -g "${NODE_RG}" -n "${VMSS}" --query "[].instanceId" -o tsv); do
  log "Wiring containerd on instance ${id}"
  az vmss run-command invoke --subscription "${SUBSCRIPTION}" -g "${NODE_RG}" -n "${VMSS}" \
    --instance-id "${id}" --command-id RunShellScript --scripts @/tmp/_wire_containerd.sh \
    --query "value[0].message" -o tsv 2>&1 | grep -iE "containerd:|WARN|error" | sed 's/^/     /' || true
done
ok "nvidia runtime wired into containerd (legacy mode, driverRoot=${DRIVER_ROOT}). RuntimeClass 'nvidia' ready."
