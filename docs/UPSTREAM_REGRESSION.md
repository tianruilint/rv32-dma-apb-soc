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

The original `friscv_memfy` ignored RRESP/BRESP. On SLVERR it still wrote
`0xdeadbeef` into the destination register, the CPU never trapped, and a
younger instruction retired.

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

Serialising in the load/store unit was not enough. The control unit's JAL
path did not check the memory-busy condition, so a younger JAL wrote its
link register before the older load faulted. Before the control patch,
the ADDI cases passed and the first JAL case failed.
`friscv_control_retirement.patch` makes JAL, EBREAK and FENCE.I wait. It
also makes a queued older fault win over a younger synchronous exception.
After the patch, 30/30 cases pass in each pipeline mode.

### IRQ preempts an older fault

See [VERIFICATION.md](VERIFICATION.md#the-irqfault-fix).

### Crossbar testbench model issues (no RTL change)

- 128-bit runs failed 0/9 because the test pattern generator returned a
  signed integer: `0x80808080` was sign-extended on one side and
  zero-extended on the other. `axi_crossbar_bfm_width.patch` makes it an
  unsigned 32-bit value.
- After the undriven AXI4-only outputs were tied to zero, the slave monitor
  failed because it expected full-AXI fields in Lite mode. Before that, the
  outputs were X, and `!=` silently passed them.
  `axi_crossbar_bfm_contract.patch` checks Lite fields only in Lite mode,
  fills in the missing AR expectations, and uses `!==` so that X is caught.
  Three deliberately broken interfaces confirm that the monitor now catches
  each problem.

### Mistakes in my own scripts

- An early REPL run waited for the wrong exit string, so a passing simulation
  was marked failed. The expected string now matches the source.
- The upstream argument parser swallowed `--tc` when `--novcd` came before
  it, so two ISA groups exited before simulating. The flag now goes last.
- Shell checks of the form `[[ ... ]] && grep` do not fail under `set -e`.
  The runners now use explicit `if ...; then exit 1`.
