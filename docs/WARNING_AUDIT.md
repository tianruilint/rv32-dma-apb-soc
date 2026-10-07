# Verilator warning audit

The first system build had 520 Verilator warnings (161 more in the crossbar
wiring test), mostly in the third-party CPU. Instead of waiving them as a
block, I went through them one by one. Several pointed at real bugs.

All 681 original diagnostics, with their disposition, are in
[initial_inventory.json](../reports/warning_audit/initial_inventory.json).
The raw initial build logs are kept next to it; the local checkout path in
their `make` directory lines is shown as `<repo>`.

## Warnings that were real bugs

| Warning | Cause | Fix and test |
| --- | --- | --- |
| `arprot_ffd` undriven in the cache block fetcher | a cache-miss replay registered address and ID but not PROT | PROT registered; a four-state test covers all 8 values |
| `rresp` unused in control / I-cache | fetch bus errors were executed as instructions | errors propagated, no cache fill; SLVERR/DECERR with cache on and off, then `MRET` refetch |
| PC bits unused in the exception FIFO | memory faults could report a newer PC in `mepc` | original request PC stored in the FIFO |
| (follow-up review of the same paths) | younger JAL/EBREAK/FENCE.I bypass the memory-busy check | see [UPSTREAM_REGRESSION.md](UPSTREAM_REGRESSION.md) |
| interrupt cause logic ignores global MIE | a masked interrupt was reported as the cause of a fetch fault | cause chosen only when an async trap is actually taken |

The other changes are hygiene: explicit width casts, zeroing reserved or
disabled outputs, and a 64-bit multiply container reduced to XLEN. None of
these change behaviour on a valid path.

## The gate

After the fixes, the patched system build has 481 diagnostics and the
crossbar test has 142:

| Category | System | Crossbar | Meaning |
| --- | ---: | ---: | --- |
| UNUSEDSIGNAL | 218 | 47 | fields unused in this configuration |
| PINCONNECTEMPTY | 161 | 84 | outputs left unconnected on purpose |
| UNUSEDPARAM | 50 | 11 | parameters for other configurations |
| GENUNNAMED / UNUSEDGENVAR / VARHIDDEN | 27 | 0 | naming style |
| PROCASSINIT / BLKSEQ | 21 | 0 | testbench only |
| UNSIGNED / SYNCASYNCNET | 4 | 0 | zero-base range compare, reset gating, UART sampling |

`scripts/check_warnings.py` compares every lint diagnostic against
`docs/warning_waivers.json`. The match is on type, file, line, column, full
message and count, plus the SHA-256 of every involved source file. A new
warning, a changed message or a changed source file fails the gate.
UNDRIVEN, WIDTH, LATCH, MULTIDRIVEN and combinational-loop warnings cannot
be waived at all. There is no "accept current warnings" option.

```bash
python3 scripts/check_warnings.py system reports/p2_soc/system-lint.log
python3 scripts/check_warnings.py upstream-crossbar reports/p2_soc/upstream-xbar-lint.log
python3 scripts/test_warning_gate.py   # 4 negative tests the gate must reject
```

When the IRQ fix changed `friscv_control.sv`, the gate rejected its new
source hash. The 481 diagnostics were unchanged, so only that one hash was
updated.
