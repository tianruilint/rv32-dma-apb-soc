// SPDX-License-Identifier: CERN-OHL-S-2.0
#include <stdint.h>

// Memory map is summarized in docs/FINAL_RELEASE.md. The two buffers,
// guard words and terminal result all fall inside the uncached CPU window.
#define SOURCE_ADDR       0x000C0000u
#define DEST_ADDR         0x000C1000u
#define RESULT_ADDR       0x000C1F00u
#define COPY_WORDS        64u
#define DMA_BASE          0x00100040u
#define DMA_SRC           (DMA_BASE + 0x00u)
#define DMA_DST           (DMA_BASE + 0x04u)
#define DMA_LEN_BYTES     (DMA_BASE + 0x08u)
#define DMA_CTRL          (DMA_BASE + 0x0Cu)
#define DMA_STATUS        (DMA_BASE + 0x10u)
#define DMA_BUSY          (1u << 0)
#define DMA_DONE          (1u << 1)
#define DMA_ERROR         (1u << 2)
#define DMA_IRQ_PENDING   (1u << 3)

#define UART_CTRL         0x00100008u
#define UART_CLKDIV       0x0010000Cu
#define UART_TX           0x00100010u

#define TIMER_CTRL        0x00100080u
#define TIMER_PERIOD      0x00100084u
#define TIMER_COUNT       0x00100088u
#define TIMER_STATUS      0x0010008Cu

#define GUARD0_ADDR       0x000C0100u
#define GUARD1_ADDR       0x000C0FFCu
#define GUARD2_ADDR       0x000C1100u
#define GUARD3_ADDR       0x000C1FFCu
#define GUARD0_VALUE      0xA11CE001u
#define GUARD1_VALUE      0xBEEF1002u
#define GUARD2_VALUE      0xC0DE2003u
#define GUARD3_VALUE      0xD00D3004u

#define RESULT_PASS       0x600D600Du
#define RESULT_FAIL_BASE  0xBAD00000u
#define POLL_LIMIT        20000u
#define IRQ_TIMER_COUNT   0x000C1F10u
#define IRQ_DMA_COUNT     0x000C1F14u
#define IRQ_LAST_CAUSE    0x000C1F18u
#define FOREGROUND_ADDR   0x000C1F20u
#define FOREGROUND_VALUE  0x5A31C0DEu

static inline void write32(uint32_t addr, uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)addr = value;
}

static inline uint32_t read32(uint32_t addr) {
    return *(volatile uint32_t *)(uintptr_t)addr;
}

static uint32_t pattern(uint32_t index) {
    // An odd multiplier makes these 64 32-bit values distinct modulo 2^32.
    return 0xC0010000u ^ (index * 0x01020305u);
}

static void uart_puts(const char *text) {
    while (*text != '\0') {
        // The upstream UART target backpressures TX writes if its FIFO is full.
        write32(UART_TX, (uint32_t)(uint8_t)*text);
        ++text;
    }
}

__attribute__((noreturn)) static void halt(void) {
    for (;;) __asm__ volatile ("nop");
}

__attribute__((noreturn)) static void fail(uint32_t reason) {
    write32(RESULT_ADDR, RESULT_FAIL_BASE | reason);
    uart_puts("P2_DMA_FAIL\n");
    halt();
}

#ifdef P2_INTERRUPT_DEMO
// GCC emits the register save/restore and MRET for a machine interrupt ISR.
// The counters are in the same uncached RAM window as the DMA buffers.
void __attribute__((interrupt("machine"), aligned(4))) p2_interrupt(void) {
    uint32_t cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    write32(IRQ_LAST_CAUSE, cause);
    if (cause != 0x8000000Bu) fail(11u);
    if ((read32(TIMER_STATUS) & 1u) != 0u) {
        write32(TIMER_STATUS, 1u);
        if ((read32(TIMER_STATUS) & 1u) != 0u) fail(12u);
        write32(IRQ_TIMER_COUNT, read32(IRQ_TIMER_COUNT) + 1u);
    }
    if ((read32(DMA_STATUS) & DMA_IRQ_PENDING) != 0u) {
        write32(DMA_STATUS, DMA_IRQ_PENDING);
        if ((read32(DMA_STATUS) & DMA_IRQ_PENDING) != 0u) fail(13u);
        write32(IRQ_DMA_COUNT, read32(IRQ_DMA_COUNT) + 1u);
    }
}

static void enable_interrupts(void) {
    write32(IRQ_TIMER_COUNT, 0u);
    write32(IRQ_DMA_COUNT, 0u);
    write32(IRQ_LAST_CAUSE, 0u);
    const uintptr_t vector = (uintptr_t)&p2_interrupt;
    const uint32_t external = 1u << 11;
    __asm__ volatile ("csrw mtvec, %0" :: "r"(vector) : "memory");
    __asm__ volatile ("csrw mie, %0" :: "r"(external) : "memory");
    __asm__ volatile ("csrsi mstatus, 8" ::: "memory");
}
#endif

int main(void) {
    volatile uint32_t *const source = (volatile uint32_t *)(uintptr_t)SOURCE_ADDR;
    volatile uint32_t *const dest = (volatile uint32_t *)(uintptr_t)DEST_ADDR;
    uint32_t status = 0;

    // The UART bit clock is CLKDIV+1=5 core clocks in the pinned upstream RTL.
    // Disable it while changing the divider, then enable before any marker.
    write32(UART_CTRL, 0u);
    write32(UART_CLKDIV, 4u);
    write32(UART_CTRL, 1u);
    write32(RESULT_ADDR, 0u);

    // Exercise the CPU -> upstream crossbar -> P2 AXI/APB bridge -> P2 timer path.
    // The second firmware image exercises actual CPU interrupt entry/return.
#ifdef P2_INTERRUPT_DEMO
    enable_interrupts();
#endif
    write32(TIMER_PERIOD, 7u);
    if (read32(TIMER_PERIOD) != 7u) fail(7u);
#ifdef P2_INTERRUPT_DEMO
    write32(TIMER_CTRL, 5u);
    for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
        if (read32(IRQ_TIMER_COUNT) == 1u) break;
        if (poll == POLL_LIMIT-1u) fail(14u);
    }
    if (read32(TIMER_COUNT) != 0u) fail(9u);
#else
    write32(TIMER_CTRL, 1u);
    for (uint32_t poll = 0; poll < 1000u; ++poll) {
        if ((read32(TIMER_STATUS) & 1u) != 0u) break;
        if (poll == 999u) fail(8u);
    }
    if (read32(TIMER_COUNT) != 0u) fail(9u);
    write32(TIMER_STATUS, 1u);
    if ((read32(TIMER_STATUS) & 1u) != 0u) fail(10u);
#endif

    for (uint32_t i = 0; i < COPY_WORDS; ++i) {
        source[i] = pattern(i);
        dest[i] = 0u;
    }
    write32(GUARD0_ADDR, GUARD0_VALUE);
    write32(GUARD1_ADDR, GUARD1_VALUE);
    write32(GUARD2_ADDR, GUARD2_VALUE);
    write32(GUARD3_ADDR, GUARD3_VALUE);

    // Volatile stores are completed in program order by the CPU/bus contract.
    // This test depends on the SoC's uncached map for both buffer windows.
    write32(DMA_STATUS, DMA_DONE | DMA_ERROR | DMA_IRQ_PENDING);
    write32(DMA_SRC, SOURCE_ADDR);
    write32(DMA_DST, DEST_ADDR);
    write32(DMA_LEN_BYTES, COPY_WORDS * sizeof(uint32_t));
    write32(FOREGROUND_ADDR, FOREGROUND_VALUE);
#ifdef P2_INTERRUPT_DEMO
    write32(DMA_CTRL, 3u);
#else
    write32(DMA_CTRL, 1u);
#endif

    for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
        // Deliberate uncached CPU RAM traffic while the DMA master is active.
        if (read32(FOREGROUND_ADDR) != FOREGROUND_VALUE) fail(17u);
        status = read32(DMA_STATUS);
        if ((status & DMA_ERROR) != 0u) fail(1u);
        if ((status & DMA_DONE) != 0u) break;
    }
    if ((status & DMA_DONE) == 0u) fail(2u);
    if ((status & DMA_BUSY) != 0u) fail(3u);
#ifdef P2_INTERRUPT_DEMO
    for (uint32_t poll = 0; poll < POLL_LIMIT; ++poll) {
        if (read32(IRQ_DMA_COUNT) == 1u) break;
        if (poll == POLL_LIMIT-1u) fail(15u);
    }
    if (read32(IRQ_TIMER_COUNT) != 1u || read32(IRQ_LAST_CAUSE) != 0x8000000Bu) fail(16u);
#endif

    for (uint32_t i = 0; i < COPY_WORDS; ++i) {
        const uint32_t expected = pattern(i);
        if (source[i] != expected) fail(4u);
        if (dest[i] != expected) fail(5u);
    }
    if (read32(GUARD0_ADDR) != GUARD0_VALUE ||
        read32(GUARD1_ADDR) != GUARD1_VALUE ||
        read32(GUARD2_ADDR) != GUARD2_VALUE ||
        read32(GUARD3_ADDR) != GUARD3_VALUE) fail(6u);

    uart_puts("P2_DMA_PASS\n");
    write32(RESULT_ADDR, RESULT_PASS);
    halt();
}
