# Integrating the upstream AXI-Lite crossbar

Notes from when I first integrated the crossbar. For the
current design and results, see [DESIGN.md](../../docs/DESIGN.md) and
[VERIFICATION.md](../../docs/VERIFICATION.md).

## Wiring

- `rtl/soc/p2_upstream_axil_fabric.sv` only maps ports, address ranges,
  routes and IDs. Arbitration, response routing and DECERR come from the
  upstream `axicb_crossbar_lite_top`.
- Initiators: CPU instruction → RAM; CPU data → all four targets; DMA → RAM;
  the fourth port is idle. ID masks are `0x80/0x10/0x20/0x40`.
- The upstream `MST0_RW` parameter is not actually used inside the RTL, so it
  cannot block instruction-port writes. Instead the top level ties that write
  channel idle. A directed test checks that the instruction port gets DECERR
  outside RAM.

## Steps

1. `bash scripts/run_upstream_xbar.sh`: `P2_UPSTREAM_XBAR_PASS`. Checks three
   initiators and four targets, same-target contention, independent progress
   to different targets, AW/W ordering and backpressure, B/R IDs, illegal
   routes, unmapped DECERR and reset.
2. First full-system run with the original FRISCV IO block: the simulation hit
   the 500,000-cycle guard with `DMA R/W=0/0`
   (`system-upstream-io-red.log`).
3. A temporary handshake probe (`system-upstream-io-probe.log`) showed the
   CPU's write with `id=0x12` reaching the IO block, which accepted both AW
   and W but never returned `B id=0x12`. The B responses for the neighbouring
   IDs did arrive. That led to the same-cycle AW/W bug in
   `tb/upstream_friscv/README.md`.
4. With the one-line IO patch applied to the build copy, `make soc-system`:
   `SOC_SYSTEM_PASS cycles=4368 DMA R/W=16/16 ... UART=P2_DMA_PASS`
   (`system-test.log`).
