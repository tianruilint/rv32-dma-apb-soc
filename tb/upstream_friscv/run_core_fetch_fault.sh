#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
cd "$(dirname "$0")/../.."
mkdir -p build/core_fetch_fault reports/upstream_friscv
python3 scripts/prepare_upstream.py > reports/upstream_friscv/fetch-fault-prepare.log 2>&1
for variant in original hardened; do
  source_root=third_party/friscv
  if [[ $variant == hardened ]]; then source_root=build/p2_upstream_hardened; fi
  sources=()
  for f in "$source_root"/rtl/*.sv; do
    case "$f" in *_h.sv|*/friscv_checkers.sv|*/friscv_rv32i_platform.sv|*/friscv_stats.sv) continue;; esac
    sources+=("$f")
  done
  for cache_mode in 0 1; do
  stem="$variant-cache$cache_mode"
  verilator --binary --timing --assert -j 4 -Wno-fatal -GCACHE_MODE="$cache_mode" \
    -I"$source_root/rtl" -Ithird_party/friscv/dep/svlogger \
    --top-module core_fetch_fault_tb --Mdir "build/core_fetch_fault/$stem" \
    "${sources[@]}" tb/upstream_friscv/core_fetch_fault_tb.sv \
    > "reports/upstream_friscv/core-fetch-$stem-build.log" 2>&1
  set +e
  timeout 60 "build/core_fetch_fault/$stem/Vcore_fetch_fault_tb" \
    > "reports/upstream_friscv/core-fetch-$stem-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == original ]]; then
    if [[ $result == 0 || $result == 124 ]]; then
      echo "Unexpected original result: $result" >&2
      exit 1
    fi
    grep -q FETCH_FAULT_NOT_TRAPPED "reports/upstream_friscv/core-fetch-$stem-test.log"
  else
    if [[ $result != 0 ]]; then
      cat "reports/upstream_friscv/core-fetch-$stem-test.log" >&2
      exit 1
    fi
    grep -q CORE_FETCH_FAULT_PASS "reports/upstream_friscv/core-fetch-$stem-test.log"
    if grep -Eq '%Fatal|%Error|FATAL:|Assertion failed' "reports/upstream_friscv/core-fetch-$stem-test.log"; then
      cat "reports/upstream_friscv/core-fetch-$stem-test.log" >&2
      exit 1
    fi
  fi
  cat "reports/upstream_friscv/core-fetch-$stem-test.log"
  done
done
echo 'CORE_FETCH_RED_GREEN_PASS original_reproduced=1 hardened_pass=1'
