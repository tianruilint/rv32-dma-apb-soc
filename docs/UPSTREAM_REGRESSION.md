# Upstream regression and CPU fault fixes

```bash
python3 scripts/run_upstream_regression.py
bash tb/upstream_friscv/run_core_data_fault.sh
```

Each run builds a fresh copy under `build/upstream_regression/<UTC>/` and
saves logs, the exact commands, pinned versions, tool versions and patch
hashes to `reports/upstream_regression/<UTC>/`. `third_party/friscv` is never
modified. The SVUT test runner is fetched at pinned commit `d75f9ee`.

## Matrix

| Set | Runs | Configuration |
| --- | ---: | --- |
| Original FRISCV WBA tests | 11 | `rv32ui-p-test0..10`, platform, Icarus, cache on |
| Same tests with all patches | 11 | must still pass after the fixes |
| RV32I ISA images | 39 | all `rv32ui-p-*` |
| RV32M ISA images | 8 | all `rv32um-p-*` |
| REPL and CoreMark | 2 | Verilator; UART script and CoreMark CRC self-check |
| Crossbar, 32-bit data | 9 | 4×4, Lite, pipeline on, no CDC, 1024 transactions each |
| Crossbar, 128-bit data | 9 | same, at the width this SoC uses |

All runs check the exit code, the simulator pass count and the logs:
`%Fatal`, `%Error`, `FATAL:` or a failed assertion fails a run even if it
printed PASS. Only one crossbar configuration (Lite, no CDC, pipelined) is
exercised. CoreMark is used only as a CRC functional check, because the
upstream timer port does not give valid scores.

## Bugs found and fixed

### Load/store unit ignores bus errors

`friscv_memfy_fault.patch` keeps the PC, instruction and address of each
outstanding request. SLVERR/DECERR raise a load/store access fault, and a
failed load does not write back. Memory instructions are serialised so that
a younger instruction cannot retire first.

`friscv_memfy_fault_tb.sv` runs 39 unit checks. `core_data_fault_tb.sv` runs
60 full-CPU cases: pipeline 0/1 × load miss / store miss / store hit ×
SLVERR / DECERR × a younger ADDI, JAL, EBREAK, FENCE.I or ECALL. Each case
checks:
- `mcause` = 5 or 7, `mepc`, `mtval`
- that the younger instruction did not retire
- that the handler can re-read the old, uncorrupted value

### Younger JAL retires before the older fault

`friscv_control_retirement.patch` makes JAL, EBREAK and FENCE.I wait. It
also makes a queued older fault win over a younger synchronous exception.

### IRQ preempts an older fault

See [VERIFICATION.md](VERIFICATION.md#the-irqfault-fix).

### Crossbar testbench model issues (no RTL change)

  `axi_crossbar_bfm_contract.patch` checks Lite fields only in Lite mode,
  fills in the missing AR expectations, and uses `!==` so that X is caught.
