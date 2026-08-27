#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

expected_commit=5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba
actual_commit=$(git -C third_party/friscv rev-parse HEAD)
if [[ "$actual_commit" != "$expected_commit" ]]; then
    printf 'Unexpected FRISCV commit: %s\n' "$actual_commit" >&2
    exit 1
fi

mkdir -p build/upstream_friscv_io reports/upstream_friscv
isolated_root=$(mktemp -d build/upstream_friscv_io/patch.XXXXXXXX)
cp -a third_party/friscv/. "$isolated_root/friscv"
patch --batch -p1 -d "$isolated_root/friscv" \
    -i "$PWD/tb/upstream_friscv/friscv_io_same_cycle_write.patch" \
    > reports/upstream_friscv/patch-apply.log

compile_io() {
    local source_root=$1
    local label=$2
    local -a source_files=()
    local unit
    for unit in friscv_io_subsystem friscv_apb_interconnect friscv_gpios \
                friscv_uart friscv_clint friscv_scfifo friscv_bit_sync \
                friscv_ram friscv_rambe; do
        source_files+=("$source_root/rtl/$unit.sv")
    done
    iverilog -g2012 -DFRISCV_SIM -I"$source_root/rtl" \
        -s friscv_io_write_red_tb \
        -o "$isolated_root/$label.vvp" \
        tb/upstream_friscv/friscv_io_write_red_tb.sv "${source_files[@]}" \
        > "reports/upstream_friscv/$label-build.log" 2>&1
}

compile_io third_party/friscv red
if vvp "$isolated_root/red.vvp" > reports/upstream_friscv/red-test.log 2>&1; then
    echo 'Expected the unmodified FRISCV IO test to fail, but it passed.' >&2
    exit 1
fi
grep -Fq 'FRISCV_IO_GPIO_AFTER_WRITE=12345678' reports/upstream_friscv/red-test.log
grep -Fq 'FRISCV_IO_SAME_CYCLE_WRITE_MISSING_B' reports/upstream_friscv/red-test.log
printf 'IO_RED_EXPECTED_FAILURE missing B response; see reports/upstream_friscv/red-test.log\n'

compile_io "$isolated_root/friscv" green
vvp "$isolated_root/green.vvp" > reports/upstream_friscv/green-test.log 2>&1
python3 scripts/check_sim_log.py reports/upstream_friscv/green-test.log \
    'FRISCV_IO_SAME_CYCLE_WRITE_B_RESPONDED id=5a resp=0'
printf 'IO_GREEN_PASS response id=5a resp=0\n'
