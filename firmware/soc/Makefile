# SPDX-License-Identifier: CERN-OHL-S-2.0
PREFIX ?= riscv64-unknown-elf-
CC := $(PREFIX)gcc
OBJCOPY := $(PREFIX)objcopy
OBJDUMP := $(PREFIX)objdump
PYTHON ?= python3
BUILD := ../../build/p2_soc_fw
ARCH := rv32im_zicsr
COMMON := -march=$(ARCH) -mabi=ilp32 -mcmodel=medany -msmall-data-limit=0
CFLAGS := $(COMMON) -O2 -ffreestanding -fno-builtin -fno-pic -fno-pie -Wall -Wextra -Werror -std=c11
LDFLAGS := $(COMMON) -nostdlib -nostartfiles -static -Wl,--no-relax,--fatal-warnings -T linker.ld

.PHONY: all clean
all: $(BUILD)/p2_dma_demo.mem $(BUILD)/p2_irq_demo.mem

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/main.o: main.c Makefile | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/main_irq.o: main.c Makefile | $(BUILD)
	$(CC) $(CFLAGS) -DP2_INTERRUPT_DEMO -c $< -o $@

$(BUILD)/crt0.o: crt0.S Makefile | $(BUILD)
	$(CC) $(COMMON) -c $< -o $@

$(BUILD)/p2_dma_demo.elf: $(BUILD)/crt0.o $(BUILD)/main.o linker.ld Makefile
	$(CC) $(LDFLAGS) -Wl,-Map,$(@:.elf=.map) $(BUILD)/crt0.o $(BUILD)/main.o -o $@
	$(OBJDUMP) -d $@ > $(BUILD)/p2_dma_demo.dis

$(BUILD)/p2_irq_demo.elf: $(BUILD)/crt0.o $(BUILD)/main_irq.o linker.ld Makefile
	$(CC) $(LDFLAGS) -Wl,-Map,$(@:.elf=.map) $(BUILD)/crt0.o $(BUILD)/main_irq.o -o $@
	$(OBJDUMP) -d $@ > $(BUILD)/p2_irq_demo.dis

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.mem: $(BUILD)/%.bin bin_to_mem128.py Makefile
	$(PYTHON) bin_to_mem128.py $< $@ --base 0x10000

clean:
	rm -rf $(BUILD)
