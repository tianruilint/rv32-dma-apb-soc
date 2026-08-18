# P2 SoC DMA demonstration firmware

Build from the repository root with `make -C firmware/soc`. The freestanding
RV32IM_Zicsr program starts at byte address `0x00010000`; the linker puts its
stack top at `0x00080000`. The build outputs ELF, disassembly, binary, map and
`p2_dma_demo.mem` under ignored `build/p2_soc_fw/`.

The `.mem` file is for a 128-bit-wide `$readmemh` RAM indexed by byte address
shifted right four. It starts with `@00001000` (byte address `0x00010000`) and
has one 32-digit hex word per line. Within each word, the least significant
hex byte is the lowest addressed byte. `bin_to_mem128.py` checks a full
roundtrip against the linked binary after writing the file.

The program first programs and polls the P2 APB timer through the P2 bridge,
checking PERIOD, expiration, COUNT and W1C STATUS. It then fills 64 distinct
source words at `0x000C0000`, zeros 64
destination words at `0x000C1000`, initializes four guard words, and starts
the DMA for 256 bytes. It polls with a 20,000-read limit, checks every source
and destination word plus all guards, and sends `P2_DMA_PASS\n` or
`P2_DMA_FAIL\n` through the upstream UART TX register. It writes
`0x600D600D` on success or `0xBAD00000 | reason` on failure to the uncached
terminal word at `0x000C1F00`, then loops forever. The UART divider is four,
which the pinned upstream TX FSM interprets as five core clocks per bit; the
SoC must drive UART CTS high for transmission.

This build confirms the firmware image and instruction encoding. It does not
prove execution, the uncached buffer map, DMA behavior, or UART output; those
need the integrated SoC simulation.
