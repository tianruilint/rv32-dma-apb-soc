#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/cache_prot_replay reports/upstream_friscv
python3 scripts/prepare_upstream.py > reports/upstream_friscv/hardening-prepare.log 2>&1
for variant in original hardened; do
  source_root=third_party/friscv
  defines=()
  if [[ $variant == hardened ]]; then source_root=build/p2_upstream_hardened; defines=(-DP2_HARDENED); fi
  iverilog -g2012 "${defines[@]}" -s cache_prot_replay_tb -I "$source_root/rtl" \
    -o "build/cache_prot_replay/$variant.vvp" \
    "$source_root/rtl/friscv_ram.sv" "$source_root/rtl/friscv_scfifo.sv" \
    "$source_root/rtl/friscv_cache_block_fetcher.sv" tb/upstream_friscv/cache_prot_replay_tb.sv \
    > "reports/upstream_friscv/cache-prot-$variant-build.log" 2>&1
  set +e
  vvp "build/cache_prot_replay/$variant.vvp" > "reports/upstream_friscv/cache-prot-$variant-test.log" 2>&1
  result=$?
  set -e
  if [[ $variant == original ]]; then
    if [[ $result != 1 ]]; then
      echo "Unexpected original result: $result" >&2
      exit 1
    fi
    grep -q CACHE_PROT_REPLAY_FAIL "reports/upstream_friscv/cache-prot-$variant-test.log"
  else
    if [[ $result != 0 ]]; then
      cat "reports/upstream_friscv/cache-prot-$variant-test.log" >&2
      exit 1
    fi
    grep -q CACHE_PROT_REPLAY_PASS "reports/upstream_friscv/cache-prot-$variant-test.log"
    if grep -Eq '%Fatal|%Error|FATAL:|Assertion failed' "reports/upstream_friscv/cache-prot-$variant-test.log"; then
      cat "reports/upstream_friscv/cache-prot-$variant-test.log" >&2
      exit 1
    fi
  fi
  cat "reports/upstream_friscv/cache-prot-$variant-test.log"
done
echo 'CACHE_PROT_RED_GREEN_PASS original_reproduced=1 hardened_pass=1'
