#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/p2_upstream_xbar
python3 scripts/prepare_upstream.py > reports/p2_soc/xbar-upstream-prepare.log 2>&1
upstream_dir=build/p2_upstream_hardened

axicb_sources=(
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_scfifo_ram.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_scfifo.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_round_robin_core.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_round_robin.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_pipeline.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_slv_if.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_mst_if.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_slv_switch.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_mst_switch.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_switch_top.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_crossbar_top.sv"
  "$upstream_dir/dep/axi-crossbar/rtl/axicb_crossbar_lite_top.sv"
)

verilator_args=( --timing --assert -Wall -Wno-fatal \
  -I"$upstream_dir/dep/axi-crossbar/rtl" \
  --top-module soc_upstream_xbar_tb --Mdir build/p2_upstream_xbar \
  rtl/soc/p2_axil_if.sv "${axicb_sources[@]}" \
  rtl/soc/p2_upstream_axil_fabric.sv \
  tb/soc_fabric_target_model.sv tb/soc_upstream_xbar_tb.sv
)
verilator --lint-only "${verilator_args[@]}" > reports/p2_soc/upstream-xbar-lint.log 2>&1
python3 scripts/check_warnings.py upstream-crossbar reports/p2_soc/upstream-xbar-lint.log
verilator --binary -j 4 "${verilator_args[@]}" \
  > reports/p2_soc/upstream-xbar-build.log 2>&1

timeout 60 build/p2_upstream_xbar/Vsoc_upstream_xbar_tb \
  > reports/p2_soc/upstream-xbar-test.log 2>&1

python3 scripts/check_sim_log.py reports/p2_soc/upstream-xbar-test.log P2_UPSTREAM_XBAR_PASS
