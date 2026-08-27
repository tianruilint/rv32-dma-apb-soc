#!/usr/bin/env bash
# Complete, fail-closed release regression; preserve raw stdout and exit code.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p reports/p2_soc
set +e
make verify 2>&1 | tee reports/p2_soc/final-verify.log
pipeline_status=("${PIPESTATUS[@]}")
result=${pipeline_status[0]}
if [[ ${pipeline_status[1]} != 0 ]]; then result=${pipeline_status[1]}; fi
set -e
printf 'RELEASE_VERIFY_EXIT=%s\n' "$result" | tee -a reports/p2_soc/final-verify.log
if [[ $result != 0 ]]; then exit "$result"; fi
python3 scripts/record_verification.py
