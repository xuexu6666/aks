#!/usr/bin/env bash
# Shared configuration for the GB300 vanilla-arm64 GPU setup.
# Override any value via the environment, e.g.  NODE_COUNT=4 ./setup.sh

# --- Azure / cluster ---------------------------------------------------------
export SUBSCRIPTION="${SUBSCRIPTION:-<your-subscription-id>}"
export RESOURCE_GROUP="${RESOURCE_GROUP:-gb300-clustermax-rg}"
export CLUSTER_NAME="${CLUSTER_NAME:-gb300}"
export REGION="${REGION:-eastus2}"

# --- System pool (control-plane workloads; created with the cluster) ---------
# 3 nodes (not 1) so a single system-node loss doesn't take down cluster DNS/addons
# (coredns, konnectivity, metrics-server) or the MPI launcher's home.
export SYSTEM_VM_SIZE="${SYSTEM_VM_SIZE:-Standard_D4s_v5}"
export SYSTEM_POOL_SIZE="${SYSTEM_POOL_SIZE:-3}"

# --- GPU node pool -----------------------------------------------------------
export NODEPOOL="${NODEPOOL:-gb300}"
export VM_SIZE="${VM_SIZE:-Standard_ND128isr_GB300_v6}"
export NODE_COUNT="${NODE_COUNT:-18}"
export K8S_VERSION="${K8S_VERSION:-1.35.5}"
export GPU_TAINT="${GPU_TAINT:-sku=gpu:NoSchedule}"

# --- Vanilla arm64 image (delivered via UseCustomizedOSImage) ----------------
export OS_IMAGE_SUB="${OS_IMAGE_SUB:-<aks-image-gallery-subscription-id>}"
export OS_IMAGE_RG="${OS_IMAGE_RG:-AKS-Ubuntu}"
export OS_IMAGE_GALLERY="${OS_IMAGE_GALLERY:-AKSUbuntu}"
export OS_IMAGE_NAME="${OS_IMAGE_NAME:-2404gen2arm64containerd}"
export OS_IMAGE_VERSION="${OS_IMAGE_VERSION:-202606.19.0}"

# --- GPU stack ---------------------------------------------------------------
export NAMESPACE="${NAMESPACE:-nvidia}"
export GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.10.1}"
export DRA_DRIVER_VERSION="${DRA_DRIVER_VERSION:-25.12.0}"
# Official dranet (kubernetes-sigs/dranet) for non-privileged IB via DRA — step 05.
export DRANET_VERSION="${DRANET_VERSION:-v1.3.0}"
# Driver rootfs mounted on the host by the operator driver DaemonSet.
export DRIVER_ROOT="${DRIVER_ROOT:-/run/nvidia/driver}"
export DRIVER_LIB="${DRIVER_LIB:-${DRIVER_ROOT}/usr/lib/aarch64-linux-gnu}"

# --- NCCL test ---------------------------------------------------------------
export NCCL_IMAGE="${NCCL_IMAGE:-ghcr.io/coreweave/nccl-tests:12.9.1-devel-ubuntu24.04-nccl2.29.2-1-d73ec07}"

# --- IMEX --------------------------------------------------------------------
# nvidia-caps-imex-channels major (see /proc/devices); channel 0 minor 0.
export IMEX_CHANNEL_MAJOR="${IMEX_CHANNEL_MAJOR:-auto}"   # 'auto' => read /proc/devices
export IMEX_SERVER_PORT="${IMEX_SERVER_PORT:-50000}"

log()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

kctl() { kubectl "$@"; }
