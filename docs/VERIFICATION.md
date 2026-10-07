# Verification

Last full run: 2026-10-06, in a Linux checkout, `bash scripts/run_release.sh`
(which runs `make verify`), exit code 0. The source files, patches and raw
outputs are tied together by hashes in
[verification-manifest.json](../reports/p2_soc/verification-manifest.json).
The run manifest records its UTC generation time and exact source/output
hashes.

## What is run

| Set | Result | Evidence |
| --- | --- | --- |
| DMA / bridge directed tests | pass | [final-verify.log](../reports/p2_soc/final-verify.log) |
| IP stress (timer, DMA, bridge × 3 seeds) | pass | [IP audit](IP_BUG_AUDIT.md), `reports/p2_soc/ip-*-seed-*.log` |
| System scenarios | 9/9: baseline, 5 delay seeds, reset during DMA, 2 interrupt scenarios | [summary.json](../reports/p2_soc/system-stress/summary.json) |
| Crossbar wiring test | pass | `reports/p2_soc/upstream-xbar-test.log` |
| Upstream bug red/green tests | each original fails for the expected reason; each patched version passes | [UPSTREAM_REGRESSION.md](UPSTREAM_REGRESSION.md) |
| CPU load/store faults | 39 unit checks + 60 full-CPU cases | [logs](../reports/upstream_regression/memfy-fault/20261006T102836Z/) |
| IRQ vs. memory fault | 2 expected failures on the old control logic; 48 cases pass after the fix | [results.json](../reports/upstream_regression/irq-fault/20261006T102852Z/results.json) |
| Upstream suites with patches | WBA 11+11, RV32I 39, RV32M 8, REPL/CoreMark 2, crossbar 32/128-bit 9+9 | [summary.json](../reports/upstream_regression/20261006T102922Z/summary.json) |
| Crossbar test-model checks | original monitor fails as expected; fixed 32/128-bit pass; 3 broken interfaces rejected | [results.json](../reports/upstream_regression/crossbar-bfm/20261006T104302Z/results.json) |
| Protocol checker self-tests | 14/14 expected outcomes: 5 accepted flows and 9 required rejections | [results.json](../reports/p2_soc/protocol-checker/20261006T102718893683Z/results.json) |
| Lint gate | every Verilator diagnostic matched to a reviewed waiver; 0 functional warnings | [WARNING_AUDIT.md](WARNING_AUDIT.md) |

Each regression run writes a new UTC-stamped folder; only the latest
complete run is kept in the repository. Red (original-source) and green
(patched) results are both inside that run.

## What the system test checks

- 256-byte DMA copy: all 64 source/destination words and the guard words,
  DMA reads/writes = 16/16, and CPU RAM traffic while the DMA is busy.
- UART output decoded from the TX pin, independently of the testbench.
- The interrupt image: each interrupt source is serviced once, IRQ deasserts, and `MRET`
  returns to the main program.
- A protocol checker on 8 bus interfaces: VALID and payload stay stable until
  READY. Responses are checked against accepted requests, including AW/W
  pairing; a response without an eligible outstanding request is rejected.
- 5 seeds of random READY / response delays on the RAM and peripheral
  ports, and a reset in the middle of a DMA transfer.

In the recorded waveforms the 256-byte copy (first DMA AR to last DMA B)
takes 226 cycles with no extra delay and 408 cycles with seed 7. These are
latency figures for this workload, not a throughput benchmark.

The checker has an explicit `check_drained` task for endpoints where
stimulus has stopped and all requests should have completed. Its self-tests
exercise that boundary. The SoC CPU still fetches at test termination, so
the final counters are not an assertion that every interface is drained
or a general proof of eventual responses.

## The IRQ/fault fix

A test with real firmware raises an external interrupt near a load/store
that receives SLVERR/DECERR. Two failures appeared on the old control logic:

- A store fault was already queued, yet the interrupt was taken first
  (`mcause=0x8000000b`, `mepc=0x24`). The correct first trap is the store
  access fault (`mcause=7`, `mepc=0x20`, `mtval=0x00100020`).
- Between popping the exception FIFO and committing the MSTATUS write there
  was a one-cycle window in which the pending IRQ could re-enter and
  overwrite the trap state.

The fix extends `friscv_control_retirement.patch`: a queued older fault is
taken first, and no async trap is taken while the MSTATUS write is
committing. The IRQ stays pending and is delivered after the fault
handler's `MRET`.

The regression has 48 cases: pipeline 0/1 × load/store × SLVERR/DECERR ×
direct/vector `mtvec` × IRQ arriving 0/3/6 cycles early. Each case checks:
- `mcause`, `mepc` and `mtval` of the first trap
- no early retirement of younger instructions
- that the fault handler and then the IRQ handler each run once
- that the main program resumes

## Reproduce

```bash
git submodule update --init --recursive
bash scripts/run_release.sh
python3 scripts/record_verification.py --check   # re-check hashes only, no simulation
```

Any unexpected failure stops the run. Red tests must fail with their specific
expected message; an unrelated failure counts as an error.

## Not covered

- No error injection into the DMA during system tests (it is covered at unit
  level).
- No firmware recovery after a RAM error.
- Other crossbar configurations (full AXI, CDC).
- Formal proof, FPGA, and synthesis/timing of the SoC.
