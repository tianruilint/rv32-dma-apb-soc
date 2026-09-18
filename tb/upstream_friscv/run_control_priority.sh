#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/control_priority/before/rtl build/control_priority/after/rtl reports/upstream_friscv
python3 scripts/prepare_upstream.py --output build/control_priority/prepared > reports/upstream_friscv/control-priority-prepare.log 2>&1
# The red variant contains all previously reviewed fixes but excludes this patch.
cp build/control_priority/prepared/rtl/* build/control_priority/after/rtl/
cp build/control_priority/prepared/rtl/* build/control_priority/before/rtl/
if grep -Fq 'async_trap_occuring && sb_msip' build/control_priority/prepared/rtl/friscv_control.sv; then
  patch --batch --reverse --directory build/control_priority/before -p1 < tb/upstream_friscv/friscv_control_retirement.patch > reports/upstream_friscv/control-priority-reverse.log 2>&1
else
  patch --batch --forward --directory build/control_priority/after -p1 < tb/upstream_friscv/friscv_control_retirement.patch > reports/upstream_friscv/control-priority-apply.log 2>&1
fi
for variant in before after; do
  src="build/control_priority/$variant/rtl"
  iverilog -g2012 -s masked_irq_priority_tb -I "$src" \
    -o "build/control_priority/$variant.vvp" \
    "$src/friscv_control.sv" "$src/friscv_decoder.sv" "$src/friscv_scfifo.sv" "$src/friscv_ram.sv" \
    tb/upstream_friscv/masked_irq_priority_tb.sv > "reports/upstream_friscv/control-priority-$variant-build.log" 2>&1
  set +e
  vvp "build/control_priority/$variant.vvp" > "reports/upstream_friscv/control-priority-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == before ]]; then
    if [[ $result != 1 ]]; then cat "reports/upstream_friscv/control-priority-$variant-test.log" >&2; exit 1; fi
    grep -q MASKED_IRQ_PRIORITY_FAIL "reports/upstream_friscv/control-priority-$variant-test.log"
  else
    if [[ $result != 0 ]]; then cat "reports/upstream_friscv/control-priority-$variant-test.log" >&2; exit 1; fi
    python3 scripts/check_sim_log.py "reports/upstream_friscv/control-priority-$variant-test.log" MASKED_IRQ_PRIORITY_PASS
  fi
  cat "reports/upstream_friscv/control-priority-$variant-test.log"
done
bash tb/upstream_friscv/run_core_irq_fault.sh
echo CONTROL_PRIORITY_RED_GREEN_PASS
