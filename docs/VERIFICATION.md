# Verification

## What the system test checks

- 256-byte DMA copy: all 64 source/destination words and the guard words,
  DMA reads/writes = 16/16, and CPU RAM traffic while the DMA is busy.
- UART output decoded from the TX pin, independently of the testbench.
- The interrupt image: each ISR runs exactly once, IRQ deasserts, and `MRET`
  returns to the main program.
- A protocol checker on 8 bus interfaces: VALID and payload stay stable until
  READY, and every request gets exactly one response.
- 5 seeds of random READY / response delays on the RAM and peripheral
  ports, and a reset in the middle of a DMA transfer.

## The IRQ/fault fix

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
