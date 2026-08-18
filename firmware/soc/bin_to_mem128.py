#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Pack a contiguous little-endian binary into 128-bit $readmemh words."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base", type=lambda x: int(x, 0), default=0x10000)
    args = parser.parse_args()
    if args.base % 16:
        parser.error("base address must be 16-byte aligned")

    data = args.binary.read_bytes()
    if not data:
        parser.error("binary is empty")
    lines = [f"@{args.base // 16:08X}"]
    for offset in range(0, len(data), 16):
        chunk = data[offset : offset + 16].ljust(16, b"\x00")
        lines.append(f"{int.from_bytes(chunk, 'little'):032X}")
    args.output.write_text("\n".join(lines) + "\n", encoding="ascii")

    # Read every emitted word back, not just the first one. The least
    # significant hex byte becomes byte lane 0 of the 128-bit RAM word.
    emitted = args.output.read_text(encoding="ascii").splitlines()
    if args.base == 0x10000:
        assert emitted[0] == "@00001000"
    decoded = b"".join(int(word, 16).to_bytes(16, "little") for word in emitted[1:])
    assert decoded[: len(data)] == data
    assert all(len(word) == 32 for word in emitted[1:])
    print(f"MEM128_OK base=0x{args.base:08X} bytes={len(data)} words={len(emitted)-1}")


if __name__ == "__main__":
    main()
