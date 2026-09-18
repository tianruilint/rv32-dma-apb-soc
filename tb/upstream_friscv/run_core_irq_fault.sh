#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
build="build/core_irq_fault/$stamp"
report="reports/upstream_regression/irq-fault/$stamp"
mkdir -p "$build" "$report"
python3 scripts/prepare_upstream.py --output "$build/prepared" > "$report/prepare.log" 2>&1
cp "$build/prepared/manifest.json" "$report/overlay-manifest.json"
verilator --version > "$report/tool-version.txt"

# Reconstruct precisely the previous interrupt-selection expression, retaining
# all other reviewed fixes. Save the delta and hashes to make the red input clear.
python3 - "$build" "$report" <<'PY'
from pathlib import Path
import difflib
import hashlib
import json
import shutil
import sys

build, report = map(Path, sys.argv[1:])
for variant in ('before', 'after'):
    shutil.copytree(build / 'prepared' / 'rtl', build / variant / 'rtl')
after = build / 'after' / 'rtl' / 'friscv_control.sv'
before = build / 'before' / 'rtl' / 'friscv_control.sv'
fixed = '''    // A queued fault belongs to an older memory instruction. Deliver it before
    // an interrupt, keeping the interrupt pending for MRET. The control CSR
    // writes commit one cycle later; do not re-enter while MSTATUS is pending.
    assign async_trap_occuring =
        (sb_msip&sb_msie | sb_mtip&sb_mtie | sb_meip&sb_meie&!clr_meip) &
        sb_mie & !mstatus_wr &
        !(load_access_fault | store_access_fault | load_misaligned | store_misaligned);'''
previous = '    assign async_trap_occuring = (sb_msip&sb_msie | sb_mtip&sb_mtie | sb_meip&sb_meie&!clr_meip) & sb_mie;'
text = after.read_text()
if text.count(fixed) != 1:
    raise SystemExit('Expected exactly one reviewed interrupt-priority fix')
before.write_text(text.replace(fixed, previous))
(report / 'red-input-delta.patch').write_text(''.join(difflib.unified_diff(
    text.splitlines(True), before.read_text().splitlines(True),
    fromfile='after/friscv_control.sv', tofile='before/friscv_control.sv')))
inputs = {
    'before_control_sha256': hashlib.sha256(before.read_bytes()).hexdigest(),
    'after_control_sha256': hashlib.sha256(after.read_bytes()).hexdigest(),
    'testbench_sha256': hashlib.sha256(Path('tb/upstream_friscv/core_irq_fault_tb.sv').read_bytes()).hexdigest(),
    'red_scope': 'only the new enabled-IRQ/queued-fault selection fix removed; CSR commit window and old store fault are checked separately',
    'green_cases': 48,
}
(report / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
PY

for variant in before after-pipe0 after-pipe1; do
  source_root="$build/after/rtl"
  pipeline=0
  if [[ $variant == before ]]; then source_root="$build/before/rtl"; pipeline=1; fi
  if [[ $variant == after-pipe1 ]]; then pipeline=1; fi
  parameters=("-GPIPELINE=$pipeline")
  # One baseline binary reproduces the CSR window and the original store fault.
  # Both green binaries execute every one of the 24 scenarios.
  if [[ $variant == before ]]; then parameters+=(-GSCENARIOS=1); fi
  mkdir -p "$build/$variant/obj"
  sources=()
  for f in "$source_root"/*.sv; do
    case "$f" in *_h.sv|*/friscv_checkers.sv|*/friscv_rv32i_platform.sv|*/friscv_stats.sv) continue;; esac
    sources+=("$f")
  done
  verilator --binary --timing --assert -j 4 -Wno-fatal \
    -I"$source_root" -Ithird_party/friscv/dep/svlogger \
    --top-module core_irq_fault_tb "${parameters[@]}" --Mdir "$build/$variant/obj" \
    "${sources[@]}" tb/upstream_friscv/core_irq_fault_tb.sv \
    > "$report/$variant-build.log" 2>&1
  if [[ $variant == before ]]; then
    for red_case in csr-window priority; do
      scenario=0
      marker='IRQ_FAULT_PENDING_LOST pipeline=1 store=0 vector=0 irq_advance=0'
      if [[ $red_case == priority ]]; then
        scenario=6
        marker='IRQ_OVERRIDES_OLDER_FAULT pipeline=1 store=1 vector=0 irq_advance=0'
      fi
      red_log="$report/before-$red_case-test.log"
      set +e
      timeout 60 "$build/$variant/obj/Vcore_irq_fault_tb" "+scenario=$scenario" > "$red_log" 2>&1
      result=$?
      set -e
      if [[ $result == 0 || $result == 124 ]] || ! grep -q "$marker" "$red_log"; then
        cat "$red_log" >&2
        echo "Unexpected IRQ/fault baseline result: $report" >&2
        exit 1
      fi
      if [[ $red_case == csr-window ]] && ! grep -q '^IRQ_FAULT_FIRST_SYNC_PASS ' "$red_log"; then
        echo "CSR-window red did not first validate the synchronous trap: $report" >&2
        exit 1
      fi
      printf '%s\t%s\t0\n' "before-$red_case" "$result" >> "$report/executions.tsv"
      cat "$red_log"
    done
  else
    set +e
    timeout 60 "$build/$variant/obj/Vcore_irq_fault_tb" > "$report/$variant-test.log" 2>&1
    result=$?
    set -e
    if [[ $result != 0 ]] || [[ $(grep -c '^IRQ_FAULT_CASE_PASS ' "$report/$variant-test.log") != 24 ]]; then
      cat "$report/$variant-test.log" >&2
      echo "Patched IRQ/fault regression failed: $report" >&2
      exit 1
    fi
    python3 scripts/check_sim_log.py "$report/$variant-test.log" "CORE_IRQ_FAULT_PASS cases=24 pipeline=$pipeline"
    printf '%s\t%s\t24\n' "$variant" "$result" >> "$report/executions.tsv"
    cat "$report/$variant-test.log"
  fi
done
python3 - "$report" <<'PY'
from pathlib import Path
import json
import sys

report = Path(sys.argv[1])
entries = []
for line in (report / 'executions.tsv').read_text().splitlines():
    variant, code, cases = line.split('\t')
    entries.append({'variant': variant, 'exit_code': int(code), 'green_cases': int(cases)})
if len(entries) != 4 or sum(item['green_cases'] for item in entries) != 48:
    raise SystemExit('Expected exactly two precise red results and 48 green cases')
(report / 'results.json').write_text(json.dumps({
    'passed': True, 'red_reproductions': 2, 'green_cases': 48, 'executions': entries
}, indent=2) + '\n')
PY
echo "CORE_IRQ_FAULT_RED_GREEN_PASS original_reproduced=2 hardened_cases=48 reports=$report"
