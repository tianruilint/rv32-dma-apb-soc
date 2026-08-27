#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/p2_soc_dma build/p2_soc_bridge

# Top-level interface pins are intentionally undriven in a standalone bridge
# lint run. The behavioral bridge test drives every request channel.
verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  --top-module p2_axil_apb_bridge \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_axil_apb_bridge.sv \
  > reports/p2_soc/bridge-lint.log 2>&1
verilator --binary --timing --assert -Wall -Wno-UNUSEDSIGNAL \
  -Wno-PROCASSINIT -Wno-BLKSEQ -j 4 \
  --top-module soc_bridge_test --Mdir build/p2_soc_bridge \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_axil_apb_bridge.sv \
  tb/soc_bridge_test.sv \
  > reports/p2_soc/bridge-build.log 2>&1
timeout 60 build/p2_soc_bridge/Vsoc_bridge_test \
  > reports/p2_soc/bridge-test.log 2>&1
python3 scripts/check_sim_log.py reports/p2_soc/bridge-test.log SOC_BRIDGE_PASS

verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module p2_dma \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_dma.sv \
  > reports/p2_soc/dma-lint.log 2>&1
verilator --binary --timing --assert -Wall \
  -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT -j 4 \
  --top-module soc_dma_tb --Mdir build/p2_soc_dma \
  rtl/soc/p2_axil_if.sv rtl/soc/p2_dma.sv tb/soc_dma_tb.sv \
  > reports/p2_soc/dma-build.log 2>&1
timeout 60 build/p2_soc_dma/Vsoc_dma_tb \
  > reports/p2_soc/dma-test.log 2>&1
python3 scripts/check_sim_log.py reports/p2_soc/dma-test.log 'PASS soc_dma_tb 8 groups'
