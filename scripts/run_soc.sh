#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc build/p2_soc_obj

# Build the pinned MIT-licensed IO source in an ignored overlay. This
# one-line upstream bug fix is applied to the copy only; the Git submodule
# remains exactly at the reviewed SHA.
expected_friscv_sha=5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba
actual_friscv_sha=$(git -C third_party/friscv rev-parse HEAD)
if [[ "$actual_friscv_sha" != "$expected_friscv_sha" ]]; then
  echo "Unexpected FRISCV SHA: $actual_friscv_sha" >&2
  exit 1
fi
io_overlay_dir=build/p2_soc_upstream_overlay
mkdir -p "$io_overlay_dir/rtl"
cp third_party/friscv/rtl/friscv_io_subsystem.sv "$io_overlay_dir/rtl/friscv_io_subsystem.sv"
patch --batch --directory "$io_overlay_dir" -p1 \
  < tb/upstream_friscv/friscv_io_same_cycle_write.patch \
  > reports/p2_soc/io-patch-apply.log 2>&1
sha256sum third_party/friscv/rtl/friscv_io_subsystem.sv \
  "$io_overlay_dir/rtl/friscv_io_subsystem.sv" \
  > reports/p2_soc/io-source-hashes.log

make -C firmware/soc > reports/p2_soc/firmware-build.log 2>&1

# Pinned FRISCV core and IO sources. Its separate MIT-licensed axi-crossbar
# dependency supplies the SoC interconnect through a P2 port-mapping wrapper.
friscv_sources=(
  third_party/friscv/rtl/friscv_rv32i_core.sv
  third_party/friscv/rtl/friscv_control.sv
  third_party/friscv/rtl/friscv_decoder.sv
  third_party/friscv/rtl/friscv_alu.sv
  third_party/friscv/rtl/friscv_processing.sv
  third_party/friscv/rtl/friscv_memfy.sv
  third_party/friscv/rtl/friscv_registers.sv
  third_party/friscv/rtl/friscv_csr.sv
  third_party/friscv/rtl/friscv_pulser.sv
  third_party/friscv/rtl/friscv_scfifo.sv
  third_party/friscv/rtl/friscv_ram.sv
  third_party/friscv/rtl/friscv_rambe.sv
  third_party/friscv/rtl/friscv_dcache.sv
  third_party/friscv/rtl/friscv_icache.sv
  third_party/friscv/rtl/friscv_cache_block_fetcher.sv
  third_party/friscv/rtl/friscv_cache_prefetcher.sv
  third_party/friscv/rtl/friscv_cache_io_fetcher.sv
  third_party/friscv/rtl/friscv_cache_ooo_mgt.sv
  third_party/friscv/rtl/friscv_cache_pusher.sv
  third_party/friscv/rtl/friscv_cache_flusher.sv
  third_party/friscv/rtl/friscv_axi_or_tracker.sv
  third_party/friscv/rtl/friscv_cache_blocks.sv
  third_party/friscv/rtl/friscv_cache_memctrl.sv
  third_party/friscv/rtl/friscv_apb_interconnect.sv
  "$io_overlay_dir/rtl/friscv_io_subsystem.sv"
  third_party/friscv/rtl/friscv_gpios.sv
  third_party/friscv/rtl/friscv_clint.sv
  third_party/friscv/rtl/friscv_bit_sync.sv
  third_party/friscv/rtl/friscv_pipeline.sv
  third_party/friscv/rtl/friscv_uart.sv
  third_party/friscv/rtl/friscv_m_ext.sv
  third_party/friscv/rtl/friscv_div.sv
  third_party/friscv/rtl/friscv_bus_perf.sv
  third_party/friscv/rtl/friscv_mpu.sv
  third_party/friscv/rtl/friscv_pmp_region.sv
)

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
  -DFRISCV_SIM \
  -Ithird_party/friscv/rtl \
  -Ithird_party/friscv/dep/axi-crossbar/rtl \
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
  tb/soc_ram_model.sv tb/soc_system_test.sv \
  > reports/p2_soc/system-build.log 2>&1

build/p2_soc_obj/Vsoc_system_test \
  +PROGRAM_HEX=build/p2_soc_fw/p2_dma_demo.mem \
  > reports/p2_soc/system-test.log 2>&1

grep -F 'SOC_SYSTEM_PASS' reports/p2_soc/system-test.log
