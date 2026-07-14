#!/usr/bin/env bash
# One-shot: take a cluster from nothing to the final validated state and run the
# full NCCL matrix. Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "GB300 vanilla-arm64 GPU setup — full run"
./01-nodepool.sh
./02-gpu-operator.sh
./03-imex.sh
./04-nccl.sh all
ok "Done. Cluster is at the final state; all three NCCL paths exercised."
