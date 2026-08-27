/* SPDX-License-Identifier: CERN-OHL-S-2.0 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 0x00070000
}

__stack_top = 0x00080000;

/* Separate ELF code and writable-data segments. The test RAM itself has no
   protection mechanism; these flags describe the image, not a hardware MPU. */
PHDRS {
    code PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS {
    .text : ALIGN(16) {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(16);
    } > RAM :code

    .data : ALIGN(16) {
        *(.sdata .sdata.*)
        *(.data .data.*)
        . = ALIGN(16);
    } > RAM :data

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM :data

    __image_end = .;
    ASSERT(__image_end < 0x00070000, "firmware collides with its stack reserve")
}
