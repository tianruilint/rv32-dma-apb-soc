#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p reports/p2_soc build/cache_response_regression
python3 scripts/prepare_upstream.py --output build/cache_response_regression/base > reports/p2_soc/ip-cache-response-prepare.log 2>&1
# Keep an isolated before/after pair around exactly this repair.
if grep -q 'friscv_cache_write_response.patch' build/cache_response_regression/base/manifest.json; then
  patch --batch -R -p1 -d build/cache_response_regression/base < tb/upstream_friscv/friscv_cache_write_response.patch >/dev/null
fi
mkdir -p build/cache_response_regression/fixed/rtl
cp build/cache_response_regression/base/rtl/*.sv build/cache_response_regression/fixed/rtl/
patch --batch -p1 -d build/cache_response_regression/fixed < tb/upstream_friscv/friscv_cache_write_response.patch > reports/p2_soc/ip-cache-response-patch.log
for variant in base fixed; do
  src=build/cache_response_regression/$variant/rtl
  verilator --binary --timing --assert -Wno-fatal -j 4 --top-module cache_write_response_tb \
    --Mdir "build/cache_response_regression/obj_$variant" -I"$src" \
    "$src/friscv_ram.sv" "$src/friscv_scfifo.sv" "$src/friscv_cache_pusher.sv" tb/upstream_friscv/cache_write_response_tb.sv \
    > "reports/p2_soc/ip-cache-response-$variant-build.log" 2>&1
  set +e
  "build/cache_response_regression/obj_$variant/Vcache_write_response_tb" > "reports/p2_soc/ip-cache-response-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == base ]]; then
    if [[ $result == 0 ]]; then echo 'Expected cache early-completion failure was absent' >&2; exit 1; fi
    grep -q CACHE_WRITE_EARLY_COMPLETION_FAIL "reports/p2_soc/ip-cache-response-$variant-test.log"
  else
    if [[ $result != 0 ]]; then cat "reports/p2_soc/ip-cache-response-$variant-test.log"; exit "$result"; fi
    if grep -Eq '%Fatal|%Error|FATAL:|ERROR:' "reports/p2_soc/ip-cache-response-$variant-test.log"; then exit 1; fi
    grep -q CACHE_WRITE_RESPONSE_PASS "reports/p2_soc/ip-cache-response-$variant-test.log"
  fi
  cat "reports/p2_soc/ip-cache-response-$variant-test.log"
done
echo 'CACHE_WRITE_RESPONSE_RED_GREEN_PASS original_early_completion=1 delayed_and_error_responses_fixed=1'
