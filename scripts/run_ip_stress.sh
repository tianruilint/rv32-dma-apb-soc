#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/ip_timer build/ip_dma build/ip_bridge
verilator --binary --timing --assert -Wall -Wno-UNUSEDSIGNAL \
  -Wno-PROCASSINIT -Wno-DECLFILENAME -Wno-BLKSEQ -j 4 \
  --top-module soc_timer_stress_tb --Mdir build/ip_timer \
  rtl/p2_apb_timer.sv tb/soc_timer_stress_tb.sv \
  > reports/p2_soc/ip-timer-build.log 2>&1
verilator --binary --timing --assert -Wall -Wno-UNUSEDSIGNAL \
  -Wno-PROCASSINIT -j 4 --top-module soc_dma_tb --Mdir build/ip_dma \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_dma.sv tb/soc_dma_tb.sv \
  > reports/p2_soc/ip-dma-build.log 2>&1
verilator --binary --timing --assert -Wall -Wno-UNUSEDSIGNAL \
  -Wno-PROCASSINIT -Wno-BLKSEQ -j 4 \
  --top-module soc_bridge_test --Mdir build/ip_bridge \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_axil_apb_bridge.sv tb/soc_bridge_test.sv \
  > reports/p2_soc/ip-bridge-build.log 2>&1
for seed in 1 20260925 314159265; do
  timeout 90 build/ip_timer/Vsoc_timer_stress_tb +SEED="$seed" \
    > "reports/p2_soc/ip-timer-seed-$seed.log" 2>&1
  python3 scripts/check_sim_log.py "reports/p2_soc/ip-timer-seed-$seed.log" IP_TIMER_STRESS_PASS
  timeout 90 build/ip_dma/Vsoc_dma_tb +STRESS +SEED="$seed" \
    > "reports/p2_soc/ip-dma-seed-$seed.log" 2>&1
  python3 scripts/check_sim_log.py "reports/p2_soc/ip-dma-seed-$seed.log" IP_DMA_STRESS_PASS
  timeout 90 build/ip_bridge/Vsoc_bridge_test +STRESS +SEED="$seed" \
    > "reports/p2_soc/ip-bridge-seed-$seed.log" 2>&1
  python3 scripts/check_sim_log.py "reports/p2_soc/ip-bridge-seed-$seed.log" IP_BRIDGE_STRESS_PASS
done
echo 'IP_STRESS_PASS seeds=3 timer_wait_configs=3 dma_random_jobs_per_seed=27 bridge_pairs_per_seed=160'
