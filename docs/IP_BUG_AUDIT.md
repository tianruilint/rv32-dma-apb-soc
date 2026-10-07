# IP stress regression and bug review

## Interfaces and result

This covers `p2_dma`, `p2_axil_apb_bridge`, and `p2_apb_timer`. The bus
interface is a 128-bit AXI-Lite-style upstream extension with 8-bit ID sideband
and a 32-bit APB4-style register path. Standard AXI4-Lite permits 32/64-bit data;
this profile does not claim full standards compatibility or AXI bursts.
The stress regression found no functional defect in these three RTL modules.
It did expose a defect in the DMA testbench's memory slave, which was fixed,
and the timer regression runs against the current SoC interfaces.

The legal DMA operation is a non-overlapping, 16-byte-aligned copy of 16 through
4096 bytes within the first 1 MiB. A failed R/B response or returned ID ends the
job with sticky error. A hardware completion/error wins over simultaneous status
W1C. Interrupt pending is retained while masked. Reset is a reset of the DMA and
its bus domain; these tests do not assert that a DMA-only reset can cancel a
transaction already accepted by a slave that did not reset.

The bridge accepts AW and W independently, chooses one aligned 32-bit word from
the addressed lane, rejects strobes outside that lane before any APB side effect,
holds APB payload during waits, propagates slave errors, and holds AXI responses
under backpressure. Read data repeats over four lanes to support the FRISCV load
path.

The timer has CTRL, PERIOD, read-only COUNT, and W1C STATUS at offsets 0/4/8/12.
Byte strobes apply to accepted writes. Configuration writes take precedence over
that edge's countdown, period zero does not expire, one-shot mode disables on
expiration, and a new expiration wins over simultaneous pending-bit W1C.

## Testbench failure and repair

`soc_dma_tb` previously raised the memory slave's BVALID only while counting a
positive `write_latency` down from 1. With `write_latency=0`, the slave accepted
AW/W and updated RAM but never returned B. The original directed suite always
used positive latency, so it could not expose this defect.

The new test first ran unchanged DMA RTL with a zero-additional-latency slave.
It failed in `await_terminal` after the original eight groups had passed:
`DMA terminal status timeout`. The raw failed run is retained as
`reports/p2_soc/ip-dma-zero-latency-red.log`. This is a **testbench defect**, not
a newly discovered DMA RTL bug. The repair raises BVALID once when the selected
response delay is zero; positive countdown behavior remains unchanged. The
same test subsequently passes as `PASS dma_zero_additional_response_latency`.
No DUT assertion was disabled and no failing scenario was removed.

## Reproducible command

Run from the repository root in WSL Ubuntu 24.04:

```sh
bash scripts/run_ip_stress.sh
```

This compiles Verilator binaries with assertions and runs seeds `1`, `20260925`,
and `314159265`. It fails on a build error, unexpected Verilator warning, timeout,
failed assertion, missing success marker, or failed process. It does not use
`-Wno-fatal`. The explicit compile waivers are unused interface signals and
testbench-only initial values, multi-module filenames, and procedural scoreboard
blocking assignments; width, latch, multiple-driver, and incomplete-case
warnings are not globally disabled.

## Added evidence

| Test | Independent check | Executed scope |
| --- | --- | --- |
| Timer | A cycle model driven by APB pins and accepted transfers; compares read values, wait count, error decode and IRQ without looking at DUT state | 3 seeds × wait configurations 0/1/3; 845 APB transfers per configuration, total 7,605. Explicit all 16 strobe masks, period 0/1, one-shot/periodic, IRQ mask, invalid/misaligned/COUNT writes, reset abort and observed W1C/expiration collision |
| DMA | Generated immutable 128-bit expected payloads, source preservation, destination and guard comparison, read/write transaction counts, protocol stability monitors | Each seed: original 8 groups, zero-latency copy, 27 stressed jobs (4096-byte max, exact final 1-MiB source/destination beat, 24 random lengths), independently stalled AR/AW/W and response delays, all 16 register masks, register holes/window/misalignment/wrong lanes |
| DMA IRQ/race/reset | Externally observed status/IRQ and a coverage-only internal check that the intended race edge was reached | Each seed: masked pending then enable, same-cycle completion/W1C hit count 1, reset while AR/AW/W/R/B is pending (5 phases), and successful copy after resets |
| Bridge | 32-word software-style reference target plus payload/response/protocol checks | Each seed: original directed suite and 160 generated write/read pairs with random AW/W arrival skew, APB waits, response stalls, all lanes, masked writes, malformed requests and injected slave errors; 480 pairs across seeds |

Raw results are `reports/p2_soc/ip-{timer,dma,bridge}-seed-*.log`; build output is
`ip-{timer,dma,bridge}-build.log`; the console output of the whole run is in
`final-verify.log`. Successful completion prints `IP_STRESS_PASS`.

The timer oracle never reads internal DUT registers. DMA payload/status checks
also use interface observations; one explicitly commented hierarchical condition
is used solely to record that W1C decode and final B handshake really occurred
on the same edge. It is not used to compute the expected outcome.

The above is a concrete expansion of regression evidence. It is not exhaustive
formal proof or hardware signoff. Timer/DMA interrupt pins are exercised here;
CPU interrupt-handler integration is a separate system-level concern.

## Upstream data-cache write defects discovered by system stress

The independent system delay matrix subsequently exposed an upstream deadlock.
All external writes had received B responses, but the CPU's data-cache completion
tags remained reserved and the CPU never issued the following DMA-status read.
The original seed-7 system failure is preserved as
`reports/p2_soc/ip-cache-write-seed7-red.log`.

`friscv_cache_write_handshake.patch` repairs two write-interface defects:

1. The data cache gated its external AWREADY on an available completion tag but
   left WREADY ungated. Its pusher also saw ungated AWVALID. A master could retire
   W before AW, while the pusher only saved address/data when both were present.
   The tag manager then reserved a write that had no complete downstream request.
   The repair gates the pusher's AWVALID with tag availability and makes its two
   input READY signals wait for the counterpart VALID. Thus either channel can
   arrive first, and address/data are accepted together when the paired storage
   and completion tag are available.
2. Pusher discarded incoming AWPROT by driving the external value to zero. The
   patch stores the three protection bits in the same pipeline/FIFO entry as the
   address and ID. The test uses all seven nonzero values.

`bash tb/upstream_friscv/run_cache_write_backpressure.sh` runs the exact same
24-write test against original and patched source. It holds B responses to
exhaust tags, releases every downstream request, then also skews AW/W arrival.
Original source deadlocks with reserved tags and missing completions. A separate
original invocation checks the distinct `AWPROT lost` failure. Patched source
completes exactly 24 AW, 24 W, 24 external B and 24 CPU responses, with six tag
wraps, eight skewed writes, correct lane/data/protection and no residual tags.
Logs use the `reports/p2_soc/ip-cache-write-*` prefix.

## Cache-hit write errors and data preservation

Review of the same pusher found that a cache hit generated an early successful
CPU completion and changed cached data before the write-through memory returned
B. A later SLVERR/DECERR was dropped. The early completion also had no mechanism
to remain asserted if its consumer was not ready.

`friscv_cache_write_response.patch`, applied after the handshake patch, retains
address, data, byte mask and cacheability for each outstanding tag. Every write
waits for its actual B response and produces exactly one buffered CPU response.
Only an OKAY response triggers a current cache-line lookup and masked cache
update; a failed write preserves the previous cached word. The response FIFO
head is retained under backpressure. This removes the earlier cache-hit/miss
early-completion split and the associated simultaneous cache-miss/IO bookkeeping
collision.

`bash tb/upstream_friscv/run_cache_write_response.sh` preserves a before/after
pair around this specific patch. With B withheld, the original pusher changed
the cached word from `11223344` to `badc0ffe`, causing the retained red failure.
The repaired version passes four delayed responses: SLVERR and DECERR preserve
`11223344`; an OKAY write with byte mask 5 produces `11bb33dd`; a full OKAY write
produces `55667788`. Each response is held for five backpressured cycles, and
request, downstream-write and completion counts are all four. These raw results
are `reports/p2_soc/ip-cache-response-{base,fixed}-test.log`. A separate full-CPU
test maintained in the core data-fault regression prefills the real cache before
a failing store and checks that the trap handler can still read the old value.

Both red/green runners require the specific expected failure in the original
case. Every repaired case must return zero, include its success marker, and
contain no `%Fatal`, `%Error`, `FATAL:` or `ERROR:` diagnostic. During development
the first new backpressure test incorrectly fell through from `$finish` to an
unconditional fatal; that testbench control flow and the runner's false-green
check were fixed before acceptance. A PASS line alone is insufficient.
