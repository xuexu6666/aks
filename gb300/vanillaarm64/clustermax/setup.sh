#!/usr/bin/env bash
# One-shot: cluster -> GB300 pool -> GPU Operator (toolkit+DCGM+exporter, device plugin
# OFF) -> GPU DRA driver (GPUs + ComputeDomains) -> official dranet (IB) -> NCCL. Each
# step is idempotent and can be run on its own. Override anything via env (see
# variables.sh), e.g. NODE_COUNT=4 ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "clustermax GB300 full-stack setup starting"
./00-cluster.sh
./01-nodepool.sh
./02-gpu-operator.sh          # driver + toolkit(RUNTIME_CONFIG_SOURCE=file) + DCGM + exporter (device plugin OFF)
./03-dra.sh                   # GPU DRA driver — GPUs (gpu.nvidia.com) + ComputeDomains (IMEX)
./04-ib-dranet.sh             # OFFICIAL dranet — non-privileged IB via DRA (dra.net ResourceSlices)
./05-nccl.sh "${1:-all}"      # a | ib-dra | ib | mnnvl | all
ok "clustermax setup complete."
