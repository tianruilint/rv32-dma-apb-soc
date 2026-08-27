#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
report="reports/upstream_regression/memfy-fault/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p build/core_data_fault "$report"
python3 scripts/prepare_upstream.py --output build/core_data_fault/overlay > "$report/prepare.log" 2>&1
if ! grep -q 'Keep the issuing instruction' build/core_data_fault/overlay/rtl/friscv_memfy.sv; then
  patch --batch --forward -p1 -d build/core_data_fault/overlay < tb/upstream_friscv/friscv_memfy_fault.patch >> "$report/prepare.log" 2>&1
fi
# Optional candidate patches allow red/green investigation before a patch is
# accepted into the shared system build. The default uses only its fixed list.
for candidate_patch in "$@"; do
  sha256sum "$candidate_patch" >> "$report/prepare.log"
  patch --batch --forward -p1 -d build/core_data_fault/overlay < "$candidate_patch" >> "$report/prepare.log" 2>&1
done
for variant in original hardened; do
  source_root=third_party/friscv
  if [[ $variant == hardened ]]; then source_root=build/core_data_fault/overlay; fi
  iverilog -g2012 -I "$source_root/rtl" -s friscv_memfy_fault_tb \
    -o "build/core_data_fault/memfy-$variant.vvp" \
    tb/upstream_friscv/friscv_memfy_fault_tb.sv "$source_root/rtl/friscv_memfy.sv" \
    "$source_root/rtl/friscv_scfifo.sv" "$source_root/rtl/friscv_ram.sv" \
    > "$report/memfy-$variant-build.log" 2>&1
  set +e
  timeout 20 vvp "build/core_data_fault/memfy-$variant.vvp" > "$report/memfy-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == original ]]; then
    if [[ $result == 0 || $result == 124 ]] || ! grep -q 'error response raises LOAD access fault' "$report/memfy-$variant-test.log"; then
      echo "Unexpected original memfy result; see $report" >&2; exit 1
    fi
  else
    if [[ $result != 0 ]] || ! grep -q 'MEMFY_FAULT_PASS checks=39' "$report/memfy-$variant-test.log" || grep -Eq '%Fatal|%Error|FATAL:|Assertion failed' "$report/memfy-$variant-test.log"; then
      echo "Patched memfy failed; see $report" >&2; exit 1
    fi
  fi
  cat "$report/memfy-$variant-test.log"
done
for variant in original hardened hardened-pipe; do
  source_root=third_party/friscv
  pipeline=0
  if [[ $variant != original ]]; then source_root=build/core_data_fault/overlay; fi
  if [[ $variant == hardened-pipe ]]; then pipeline=1; fi
  sources=()
  for f in "$source_root"/rtl/*.sv; do
    case "$f" in *_h.sv|*/friscv_checkers.sv|*/friscv_rv32i_platform.sv|*/friscv_stats.sv) continue;; esac
    sources+=("$f")
  done
  verilator --binary --timing --assert -j 4 -Wno-fatal \
    -I"$source_root/rtl" -Ithird_party/friscv/dep/svlogger \
    --top-module core_data_fault_tb -GPIPELINE="$pipeline" --Mdir "build/core_data_fault/$variant" \
    "${sources[@]}" tb/upstream_friscv/core_data_fault_tb.sv \
    > "$report/core-$variant-build.log" 2>&1
  set +e
  timeout 60 "build/core_data_fault/$variant/Vcore_data_fault_tb" \
    > "$report/core-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == original ]]; then
    if [[ $result == 0 || $result == 124 ]] || ! grep -q DATA_FAULT_NOT_TRAPPED "$report/core-$variant-test.log"; then
      echo "Unexpected original CPU result; see $report" >&2; exit 1
    fi
  else
    if [[ $result != 0 ]] || ! grep -q 'CORE_DATA_FAULT_PASS cases=30' "$report/core-$variant-test.log" || [[ $(grep -c DATA_FAULT_CASE_PASS "$report/core-$variant-test.log") != 30 ]] || grep -Eq '%Fatal|%Error|FATAL:|Assertion failed' "$report/core-$variant-test.log"; then
      echo "Patched CPU failed ($variant); see $report" >&2; exit 1
    fi
  fi
  cat "$report/core-$variant-test.log"
done
echo "CORE_DATA_RED_GREEN_PASS original_reproduced=1 hardened_pass=2 reports=$report"
