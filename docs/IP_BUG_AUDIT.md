# P2 IP audit and stress regression

## Contract

This audit covers `p2_dma`, `p2_axil_apb_bridge`, and `p2_apb_timer`. The fixed
interface is a 128-bit AXI-Lite-style upstream extension with 8-bit ID sideband
and a 32-bit APB4-style register path. Standard AXI4-Lite permits 32/64-bit data;
this profile does not claim full standards compatibility or AXI bursts.

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
path. These are the existing interface behaviors.

The timer has CTRL, PERIOD, read-only COUNT, and W1C STATUS at offsets 0/4/8/12.
Byte strobes apply to accepted writes. Configuration writes take precedence over
that edge's countdown, period zero does not expire, one-shot mode disables on
expiration, and a new expiration wins over simultaneous pending-bit W1C.

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

The timer oracle never reads internal DUT registers. DMA payload/status checks
also use interface observations; one explicitly commented hierarchical condition
is used solely to record that W1C decode and final B handshake really occurred
on the same edge. It is not used to compute the expected outcome.

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
