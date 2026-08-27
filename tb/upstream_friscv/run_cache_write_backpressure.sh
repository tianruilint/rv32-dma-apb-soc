#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p reports/p2_soc build/cache_write_regression
python3 scripts/prepare_upstream.py --output build/cache_write_regression/overlay \
  > reports/p2_soc/ip-cache-write-prepare.log 2>&1
# The release overlay gains this patch when the parent integrates the fix.
# Until then apply it locally; never patch the pinned dependency.
for patch_name in friscv_cache_write_handshake.patch friscv_cache_write_response.patch; do
  if ! grep -q "$patch_name" build/cache_write_regression/overlay/manifest.json; then
    patch --batch -p1 -d build/cache_write_regression/overlay \
      < "tb/upstream_friscv/$patch_name" \
      >> reports/p2_soc/ip-cache-write-patch.log
  fi
done
for variant in original hardened; do
  src=third_party/friscv/rtl
  if [[ $variant == hardened ]]; then src=build/cache_write_regression/overlay/rtl; fi
  verilator --binary --timing --assert -Wno-fatal -j 4 \
    --top-module cache_write_backpressure_tb --Mdir "build/cache_write_regression/$variant" \
    -I"$src" "$src"/*.sv tb/upstream_friscv/cache_write_backpressure_tb.sv \
    > "reports/p2_soc/ip-cache-write-$variant-build.log" 2>&1
  set +e
  timeout 90 "build/cache_write_regression/$variant/Vcache_write_backpressure_tb" +DEADLOCK_ONLY \
    > "reports/p2_soc/ip-cache-write-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == original ]]; then
    if [[ $result == 0 ]]; then echo 'Expected original deadlock was absent' >&2; exit 1; fi
    grep -Eq 'write acceptance timeout|completion timeout' "reports/p2_soc/ip-cache-write-$variant-test.log"
    set +e
    timeout 90 "build/cache_write_regression/$variant/Vcache_write_backpressure_tb" \
      > reports/p2_soc/ip-cache-write-protection-red.log 2>&1
    protection_result=$?
    set -e
    if [[ $protection_result == 0 ]]; then echo 'Expected original AWPROT loss was absent' >&2; exit 1; fi
    grep -q 'AWPROT lost' reports/p2_soc/ip-cache-write-protection-red.log
  else
    if [[ $result != 0 ]]; then cat "reports/p2_soc/ip-cache-write-$variant-test.log"; exit "$result"; fi
    if grep -Eq '%Fatal|%Error|FATAL:|ERROR:' "reports/p2_soc/ip-cache-write-$variant-test.log"; then exit 1; fi
    grep -q CACHE_WRITE_BACKPRESSURE_PASS "reports/p2_soc/ip-cache-write-$variant-test.log"
    timeout 90 "build/cache_write_regression/$variant/Vcache_write_backpressure_tb" \
      > reports/p2_soc/ip-cache-write-protection-test.log 2>&1
    grep CACHE_WRITE_BACKPRESSURE_PASS reports/p2_soc/ip-cache-write-protection-test.log
    if grep -Eq '%Fatal|%Error|FATAL:|ERROR:' reports/p2_soc/ip-cache-write-protection-test.log; then exit 1; fi
  fi
  cat "reports/p2_soc/ip-cache-write-$variant-test.log"
done
echo 'CACHE_WRITE_RED_GREEN_PASS original_deadlock_reproduced=1 hardened_write_and_prot_pass=1'
