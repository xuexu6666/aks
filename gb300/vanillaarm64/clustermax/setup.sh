#!/usr/bin/env bash
# One-shot: cluster -> GB300 pool -> full GPU Operator (toolkit+device-plugin+DCGM+
# exporter) -> DRA ComputeDomains -> NCCL. Each step is idempotent and can be run
# on its own. Override anything via env (see variables.sh), e.g. NODE_COUNT=4 ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"; source ./variables.sh

log "clustermax GB300 full-stack setup starting"
./00-cluster.sh
./01-nodepool.sh
./02-gpu-operator.sh          # driver + toolkit(RUNTIME_CONFIG_SOURCE=file) + device-plugin + DCGM + exporter
./03-dra.sh                   # DRA driver — ComputeDomains only (coexists with device plugin)
./04-nccl.sh "${1:-all}"      # a | ib | mnnvl | all
ok "clustermax setup complete."
