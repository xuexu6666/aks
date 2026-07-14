#!/usr/bin/env bash
# One-shot: cluster -> final validated state (device-plugin model) + NCCL matrix.
# Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "GB300 vanilla-arm64 GPU setup — device-plugin model — full run"
./01-nodepool.sh        # GB300 pool on vanilla arm64 (--gpu-driver None)
./02-gpu-operator.sh    # GPU Operator, DRIVER ONLY -> open R580 DKMS
./03-nvidia-runtime.sh  # install toolkit binaries + wire nvidia runtime into containerd (AKS-native)
./04-device-plugin.sh   # nvidia.com/gpu (+ rdma/shared_ib) device plugins
./05-imex.sh            # IMEX per node (for cross-node NVLink / MNNVL)
./06-nccl.sh all        # a=intra NVLink, b=cross-node IB, c=cross-node MNNVL
ok "Done. Cluster at final state; NCCL matrix exercised via the device-plugin model."
