#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/p2_soc_obj

# Prepare a hashed, patched copy; upstream submodules stay at their fixed pins.
python3 scripts/prepare_upstream.py > reports/p2_soc/upstream-prepare.log 2>&1
upstream_dir=build/p2_upstream_hardened
cp "$upstream_dir/manifest.json" reports/p2_soc/upstream-manifest.json
sha256sum third_party/friscv/rtl/friscv_io_subsystem.sv \
  "$upstream_dir/rtl/friscv_io_subsystem.sv" \
  > reports/p2_soc/io-source-hashes.log

make --always-make -C firmware/soc > reports/p2_soc/firmware-build.log 2>&1

# Pinned FRISCV core and IO sources. Its separate MIT-licensed axi-crossbar
# dependency supplies the SoC interconnect through a P2 port-mapping wrapper.
friscv_sources=(
  "$upstream_dir/rtl/friscv_rv32i_core.sv"
  "$upstream_dir/rtl/friscv_control.sv"
  "$upstream_dir/rtl/friscv_decoder.sv"
  "$upstream_dir/rtl/friscv_alu.sv"
  "$upstream_dir/rtl/friscv_processing.sv"
  "$upstream_dir/rtl/friscv_memfy.sv"
  "$upstream_dir/rtl/friscv_registers.sv"
  "$upstream_dir/rtl/friscv_csr.sv"
  "$upstream_dir/rtl/friscv_pulser.sv"
  "$upstream_dir/rtl/friscv_scfifo.sv"
  "$upstream_dir/rtl/friscv_ram.sv"
  "$upstream_dir/rtl/friscv_rambe.sv"
  "$upstream_dir/rtl/friscv_dcache.sv"
  "$upstream_dir/rtl/friscv_icache.sv"
  "$upstream_dir/rtl/friscv_cache_block_fetcher.sv"
  "$upstream_dir/rtl/friscv_cache_prefetcher.sv"
  "$upstream_dir/rtl/friscv_cache_io_fetcher.sv"
  "$upstream_dir/rtl/friscv_cache_ooo_mgt.sv"
  "$upstream_dir/rtl/friscv_cache_pusher.sv"
  "$upstream_dir/rtl/friscv_cache_flusher.sv"
  "$upstream_dir/rtl/friscv_axi_or_tracker.sv"
  "$upstream_dir/rtl/friscv_cache_blocks.sv"
  "$upstream_dir/rtl/friscv_cache_memctrl.sv"
  "$upstream_dir/rtl/friscv_apb_interconnect.sv"
  "$upstream_dir/rtl/friscv_io_subsystem.sv"
  "$upstream_dir/rtl/friscv_gpios.sv"
  "$upstream_dir/rtl/friscv_clint.sv"
  "$upstream_dir/rtl/friscv_bit_sync.sv"
  "$upstream_dir/rtl/friscv_pipeline.sv"
  "$upstream_dir/rtl/friscv_uart.sv"
  "$upstream_dir/rtl/friscv_m_ext.sv"
  "$upstream_dir/rtl/friscv_div.sv"
  "$upstream_dir/rtl/friscv_bus_perf.sv"
  "$upstream_dir/rtl/friscv_mpu.sv"
  "$upstream_dir/rtl/friscv_pmp_region.sv"
)

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

verilator_args=( --timing --assert --trace --trace-depth 2 -Wall -Wno-fatal \
  -DFRISCV_SIM -DP2_PROTOCOL_CHECKS \
  -I"$upstream_dir/rtl" \
  -I"$upstream_dir/dep/axi-crossbar/rtl" \
  -Ithird_party/friscv/dep/svlogger \
  --top-module soc_system_test --Mdir build/p2_soc_obj \
  rtl/soc/p2_axil_if.sv \
  "${friscv_sources[@]}" \
  "${axicb_sources[@]}" \
  rtl/p2_apb_timer.sv \
  rtl/soc/p2_upstream_axil_fabric.sv \
  rtl/soc/p2_dma.sv \
  rtl/soc/p2_axil_apb_bridge.sv \
  rtl/soc/p2_soc_top.sv \
  tb/soc_protocol_checker.sv tb/soc_ram_model.sv tb/soc_system_test.sv
)
verilator --lint-only "${verilator_args[@]}" > reports/p2_soc/system-lint.log 2>&1
python3 scripts/check_warnings.py system reports/p2_soc/system-lint.log
verilator --binary -j 4 "${verilator_args[@]}" \
  > reports/p2_soc/system-build.log 2>&1

python3 scripts/run_system_matrix.py
