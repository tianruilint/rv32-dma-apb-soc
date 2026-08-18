#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/p2_upstream_xbar

axicb_sources=(
  third_party/friscv/dep/axi-crossbar/rtl/axicb_scfifo_ram.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_scfifo.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_round_robin_core.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_round_robin.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_pipeline.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_slv_if.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_mst_if.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_slv_switch.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_mst_switch.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_switch_top.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_crossbar_top.sv
  third_party/friscv/dep/axi-crossbar/rtl/axicb_crossbar_lite_top.sv
)

verilator --binary --timing --assert -j 4 -Wall -Wno-fatal \
  -Ithird_party/friscv/dep/axi-crossbar/rtl \
  --top-module soc_upstream_xbar_tb --Mdir build/p2_upstream_xbar \
  rtl/soc/p2_axil_if.sv "${axicb_sources[@]}" \
  rtl/soc/p2_upstream_axil_fabric.sv \
  tb/soc_fabric_target_model.sv tb/soc_upstream_xbar_tb.sv \
  > reports/p2_soc/upstream-xbar-build.log 2>&1

timeout 60 build/p2_upstream_xbar/Vsoc_upstream_xbar_tb \
  > reports/p2_soc/upstream-xbar-test.log 2>&1

grep -F 'P2_UPSTREAM_XBAR_PASS' reports/p2_soc/upstream-xbar-test.log
