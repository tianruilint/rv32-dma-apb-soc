# Patches and red/green tests for upstream FRISCV

Pinned source: `dpretet/friscv` `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba`
(MIT). `third_party/friscv` is never edited. Every `run_*.sh` script copies
the source into `build/` and builds the same testbench twice: once against the
original and once against the patched copy. The original run must fail with
the specific expected message, and the patched run must pass.

## Example: IO block drops the B response

Expected behaviour: when AWVALID and WVALID arrive in the same cycle, the IO
block performs the GPIO write and then returns exactly one B response, held
while BREADY=0.

Bug: from `IDLE`, a same-cycle AW+W moved straight to `WAIT_BRESP`. That state
never waits for the downstream ready and never raises `slv_bvalid`.
`friscv_io_same_cycle_write.patch` sends this case through `WAIT_WDATA`, which
already handles both.

```bash
bash tb/upstream_friscv/run_same_cycle_write.sh
```

Original: GPIO reads back `0x12345678`, but there is no B within 30 cycles.
Patched: `BID=0x5a`, `BRESP=OKAY`, stable under backpressure, completes once.
Logs: `reports/upstream_friscv/{red,green}-{build,test}.log`.

## Other runners

| Script | Bug it demonstrates |
| --- | --- |
| `run_cache_prot_replay.sh` | ARPROT is X on a cache-miss replay |
| `run_cache_write_backpressure.sh` | D-cache deadlocks when B is held; AWPROT lost |
| `run_cache_write_response.sh` | write hit updates the cache before B; error dropped |
| `run_core_fetch_fault.sh` | fetch bus error executed / cached |
| `run_core_data_fault.sh` | load/store errors ignored; younger instruction retires first |
| `run_control_priority.sh` | masked IRQ chosen as cause; IRQ preempts an older fault (calls `run_core_irq_fault.sh`) |
| `run_crossbar_bfm_contract.py` | crossbar test-model width/contract errors |
