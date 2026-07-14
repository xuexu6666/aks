#!/usr/bin/env bash
# One-shot: cluster -> DRA + dranet -> NCCL (gpu+nic aligned claim). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "GB300 vanilla-arm64 GPU setup — DRA + dranet — full run"
./00-cluster.sh        # resource group + AKS cluster (system pool)
./01-nodepool.sh       # GB300 pool on vanilla arm64 (--gpu-driver None)
./02-gpu-operator.sh   # GPU Operator, DRIVER ONLY -> open R580 DKMS
./03-nri.sh            # enable NRI in containerd (dranet is an NRI plugin)
./04-dra-dranet.sh     # nvidia-dra-driver-gpu (GPU slices) + dranet (NIC slices)
./05-nccl-dra.sh       # NCCL cross-node IB via a gpu-nic-aligned ResourceClaim
ok "Done."
