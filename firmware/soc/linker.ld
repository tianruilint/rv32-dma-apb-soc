/* SPDX-License-Identifier: CERN-OHL-S-2.0 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 0x00070000
}

__stack_top = 0x00080000;

SECTIONS {
    .text : ALIGN(16) {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(16);
    } > RAM

    .data : ALIGN(16) {
        *(.sdata .sdata.*)
        *(.data .data.*)
        . = ALIGN(16);
    } > RAM

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    __image_end = .;
    ASSERT(__image_end < 0x00070000, "firmware collides with its stack reserve")
}
