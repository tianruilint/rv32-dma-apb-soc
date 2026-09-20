# Design

## System

FRISCV runs bare-metal firmware. Its instruction and data ports, together with
the DMA master port, connect through the upstream AXI-Lite crossbar to RAM,
the FRISCV IO block (UART/GPIO), the DMA control registers, and the
AXI-Lite→APB bridge that fronts the timer.

| Crossbar port | Initiator | ID mask | Reaches |
| --- | --- | --- | --- |
| 0 | CPU instruction | `0x80` | RAM only (write channel tied idle at the top level) |
| 1 | CPU data | `0x10` | all targets |
| 2 | DMA | `0x20` | RAM only |
| 3 | idle | `0x40` | — |

| Address range | Target | Address passed to target |
| --- | --- | --- |
| `0x0000_0000–0x000F_FFFF` | 1 MiB behavioural RAM | absolute |
| `0x0010_0000–0x0010_003F` | FRISCV IO / UART | base subtracted |
| `0x0010_0040–0x0010_007F` | DMA control | absolute |
| `0x0010_0080–0x0010_00BF` | APB bridge → timer | absolute |

The bus has a 32-bit address, 128-bit data and an 8-bit ID. Every transfer is
a single beat. The CPU caches are enabled. `0x000C_0000–0x000C_1FFF` is mapped
uncached so that the CPU and the DMA see the same data without coherence
logic.

A CPU word access on the 128-bit bus uses lane `addr[3:2]`. Peripherals
return read data replicated in all four lanes because the FRISCV load path
expects that.

## DMA (`rtl/soc/p2_dma.sv`)

| Offset | Register | Access |
| --- | --- | --- |
| 0x00 | SRC | RW, writes rejected while busy |
| 0x04 | DST | RW, writes rejected while busy |
| 0x08 | LEN (bytes) | RW, writes rejected while busy |
| 0x0C | CTRL: [0] START (write-1 pulse), [1] IRQ_EN | RW |
| 0x10 | STATUS: [0] BUSY (RO); [1] DONE, [2] ERROR, [3] IRQ_PENDING, [4] START_REJECT (W1C) | RW1C |

- A legal job is a non-overlapping, 16-byte-aligned copy of 16–4096 bytes
  inside the first 1 MiB. START with an illegal configuration sets ERROR and
  IRQ_PENDING and returns SLVERR.
- A copy is a sequence of AR → R → AW+W → B, one 128-bit beat at a time, with
  ID `0x20`.
- A non-OKAY R or B, or a returned ID mismatch, ends the job and sets ERROR.
- START while busy returns SLVERR, sets START_REJECT, and leaves the running
  job and IRQ_EN alone.
- `irq = IRQ_EN & IRQ_PENDING`. IRQ_PENDING is recorded even while masked.
  If a hardware completion and a W1C land on the same edge, the completion wins.
- Reset cancels the job. The tests reset the whole bus domain together. They
  do not claim that resetting only the DMA can cancel a transfer that a slave
  has already accepted.

## AXI-Lite → APB bridge (`rtl/soc/p2_axil_apb_bridge.sv`)

- AW and W are buffered independently and can arrive in either order.
- `addr[3:2]` picks the 32-bit lane; `PSTRB = WSTRB[4*lane +: 4]`. Any strobe
  outside that lane gives SLVERR before an APB transfer starts.
- Standard two-phase APB (Setup, then Access). The payload is held until
  PREADY. PSLVERR is forwarded as SLVERR.
- B and R are held stable until the master accepts them.

## APB timer (`rtl/p2_apb_timer.sv`)

| Offset | Register |
| --- | --- |
| 0x0 | CTRL: enable, periodic (0 = one-shot), IRQ enable |
| 0x4 | PERIOD |
| 0x8 | COUNT (read-only; writes give PSLVERR) |
| 0xC | STATUS: expired (W1C) |

A `WAIT_CYCLES` parameter inserts PREADY wait states; the stress test runs
0, 1 and 3. A configuration write takes priority over that cycle's countdown. A period of
0 never expires. One-shot mode disables the timer on expiry. A new expiry
wins over a same-cycle W1C.

## Patches to the third-party RTL

`scripts/prepare_upstream.py` checks the pinned commits and copies the
sources to `build/p2_upstream_hardened/`. It then applies, in order:

| Patch | Fixes |
| --- | --- |
| `friscv_io_same_cycle_write.patch` | IO block never sends B when AW and W arrive together |
| `friscv_warning_hardening.patch` | cache-miss replay drops ARPROT; width and undriven-output clean-up |
| `friscv_fetch_fault.patch` | fetch bus errors executed and cached; exception FIFO missing the original PC |
| `friscv_memfy_fault.patch` | load/store unit ignores RRESP/BRESP; failed load writes the register |
| `friscv_cache_write_handshake.patch` | AW/W acceptance mismatch deadlocks the D-cache; AWPROT dropped |
| `friscv_cache_write_response.patch` | write hits complete early and update the line before B; errors lost |
| `friscv_control_retirement.patch` | younger control-flow instructions retire ahead of an older fault; IRQ preempts an older fault; masked IRQ chosen as cause |

Two more patches fix the upstream crossbar testbench models (128-bit sign
extension, and Lite vs. full-AXI field expectations). They change no RTL.

## Trade-offs I made

- **Serialised CPU memory ops.** This was the simplest way to get precise
  load/store faults in this core. It gives up the original out-of-order
  memory overlap, so I make no CPU performance claims.
- **Uncached DMA buffers** instead of cache maintenance or coherence. That is
  enough for the demo. A real system would need flush/invalidate or a
  coherent port.
- **Single-beat DMA.** It keeps the fabric AXI-Lite. Bursts would need the
  full-AXI crossbar configuration and a different DMA datapath.
- **Patching upstream in a build copy.** The pinned submodule stays pristine,
  and every fix is reviewable as a diff with its own before/after test.
