# C99 firmware for an Arduino Mega 2560, with a second board file for the
# ATmega1284P. The FreeRTOS kernel is fetched by tools/fetch-deps.sh.

BOARD ?= atmega2560
include boards/$(BOARD).mk

TARGET := stepper-interface
BUILD := build/$(BOARD)
FREERTOS := third_party/FreeRTOS-Kernel

CC := avr-gcc
OBJCOPY := avr-objcopy
OBJDUMP := avr-objdump
SIZE := avr-size
NM := avr-nm
GDB := avr-gdb
AVRDUDE := avrdude

ifeq ($(DEBUG),1)
OPT := -Og
else
OPT := -Os
endif

CPPFLAGS := -mmcu=$(MCU) -DF_CPU=$(F_CPU) -DconfigTOTAL_HEAP_SIZE=$(HEAP_SIZE)
CPPFLAGS += $(BOARD_DEFS)
CPPFLAGS += -Iinclude
CPPFLAGS += -I$(FREERTOS)/include
CPPFLAGS += -I$(FREERTOS)/portable/ThirdParty/GCC/ATmega

CFLAGS := -std=c99 $(OPT) -g
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -Wall -Wextra -Wundef -Wstrict-prototypes -Wmissing-prototypes
APP_CFLAGS := $(CPPFLAGS) $(CFLAGS) -Werror
KERNEL_CFLAGS := $(CPPFLAGS) $(CFLAGS)

LDFLAGS := -mmcu=$(MCU) -Wl,--gc-sections -Wl,-Map,$(BUILD)/$(TARGET).map

ifeq ($(BOOTLOADER),1)
APP_FLASH_LIMIT := $(shell expr $(FLASH_SIZE) - $(BOOTLOADER_SIZE))
LDFLAGS += -Wl,--defsym=__TEXT_REGION_LENGTH__=$(APP_FLASH_LIMIT)
else
APP_FLASH_LIMIT := $(FLASH_SIZE)
endif

APP_SRC := \
	src/main.c \
	src/console.c \
	src/led.c \
	src/hooks.c

KERNEL_SRC := \
	$(FREERTOS)/tasks.c \
	$(FREERTOS)/queue.c \
	$(FREERTOS)/list.c \
	$(FREERTOS)/timers.c \
	$(FREERTOS)/event_groups.c \
	$(FREERTOS)/stream_buffer.c \
	$(FREERTOS)/portable/ThirdParty/GCC/ATmega/port.c \
	$(FREERTOS)/portable/MemMang/heap_4.c

SRC := $(APP_SRC) $(KERNEL_SRC)
OBJ := $(patsubst %.c,$(BUILD)/%.o,$(SRC))
DEP := $(OBJ:.o=.d)

ELF := $(BUILD)/$(TARGET).elf
HEX := $(BUILD)/$(TARGET).hex
LSS := $(BUILD)/$(TARGET).lss
STAMP := $(FREERTOS)/.fetch-stamp

ifeq ($(V),1)
Q :=
else
Q := @
endif

.PHONY: all clean help toolchain size lst \
	flash flash-isp flash-jtag \
	fuses-read fuses-jtag fuses-noboot fuses-jtag-noboot fuses-stock \
	debug-server gdb deps

.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:

all: $(ELF) $(HEX) $(LSS)

deps: $(STAMP)

$(STAMP): tools/fetch-deps.sh tools/freertos-timer0.patch third_party/freertos.tag
	./tools/fetch-deps.sh

$(OBJ): $(STAMP)

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(Q)echo "CC  $<"
	$(Q)$(CC) $(if $(filter $(APP_SRC),$<),$(APP_CFLAGS),$(KERNEL_CFLAGS)) -MMD -MP -c $< -o $@

$(ELF): $(OBJ)
	$(Q)echo "LD  $@"
	$(Q)$(CC) $(LDFLAGS) $(OBJ) -o $@
	$(Q)ln -sfn $(BOARD)/$(TARGET).elf build/$(TARGET).elf
	$(Q)$(SIZE) -C --mcu=$(MCU) $@
	$(Q)$(MAKE) --no-print-directory -f $(firstword $(MAKEFILE_LIST)) check-image ELF=$@

$(HEX): $(ELF)
	$(Q)echo "HEX $@"
	$(Q)$(OBJCOPY) -O ihex -R .eeprom $< $@

$(LSS): $(ELF)
	$(Q)echo "LST $@"
	$(Q)$(OBJDUMP) -h -S $< > $@

# Called with ELF= so the limits for the board that was just linked are used.
check-image:
	@prog=$$($(SIZE) -C --mcu=$(MCU) $(ELF) | awk '/^Program:/{print $$2}'); \
	data=$$($(SIZE) -C --mcu=$(MCU) $(ELF) | awk '/^Data:/{print $$2}'); \
	if [ -z "$$prog" ] || [ -z "$$data" ]; then \
		echo "error: could not read avr-size output" >&2; \
		exit 1; \
	fi; \
	echo "Limit: program $(APP_FLASH_LIMIT) bytes, SRAM $(SRAM_SIZE) bytes (128 reserved for startup stack)"; \
	if [ "$$prog" -gt $(APP_FLASH_LIMIT) ]; then \
		echo "error: program $$prog exceeds $(APP_FLASH_LIMIT)" >&2; \
		exit 1; \
	fi; \
	if [ $$((data + 128)) -gt $(SRAM_SIZE) ]; then \
		echo "error: SRAM use $$data leaves under 128 bytes in $(SRAM_SIZE)" >&2; \
		exit 1; \
	fi; \
	if [ "$(THREE_BYTE_PC)" = "1" ]; then \
		found=0; \
		for hex in $$(awk '$$1 == ".lowtext" { print $$2 }' $(ELF:.elf=.map)); do \
			found=1; \
			addr=$$(printf '%d' "$$hex"); \
			if [ "$$addr" -ge 131072 ]; then \
				echo "error: .lowtext at $$hex is above the low 128 KiB" >&2; \
				exit 1; \
			fi; \
		done; \
		if [ "$$found" -eq 0 ]; then \
			echo "error: no .lowtext contributions in the map" >&2; \
			exit 1; \
		fi; \
	fi

size: $(ELF)

lst: $(LSS)

toolchain:
	$(CC) --version
	$(GDB) --version
	$(AVRDUDE) -? 2>&1 | head -n 2
	avarice --version 2>&1 | head -n 2

flash: $(HEX)
ifeq ($(USB_PROGRAMMER),)
	@echo "This board file has no USB programmer. Use flash-isp, or set USB_PROGRAMMER." >&2
	@exit 1
else
	@if [ ! -e "$(USB_PORT)" ]; then \
		echo "Serial port $(USB_PORT) is not present." >&2; \
		echo "Attach the board (on WSL: usbipd) or pass USB_PORT=/dev/ttyUSB0." >&2; \
		exit 1; \
	fi
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(USB_PROGRAMMER) -P $(USB_PORT) -b $(USB_BAUD) -D -U flash:w:$(HEX):i
endif

ifeq ($(ALLOW_BOOTLOADER_ERASE),1)
flash-isp: $(HEX)
	@echo "ISP chip-erase. Bootloader bytes in the top of flash will be gone."
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) -U flash:w:$(HEX):i
else
flash-isp:
	@echo "Refusing ISP programming: it chip-erases the device." >&2
	@if [ "$(BOOTLOADER)" = "1" ]; then \
		echo "The image leaves the boot section unused, but erase still deletes the bootloader." >&2; \
		echo "Stock Mega BOOTRST then resets into that empty section." >&2; \
		echo "After flashing, run 'make fuses-noboot ALLOW_FUSE_WRITE=1' or restore a bootloader." >&2; \
	fi
	@echo "Re-run: make flash-isp ALLOW_BOOTLOADER_ERASE=1" >&2
	@exit 1
endif

ifeq ($(ALLOW_BOOTLOADER_ERASE),1)
flash-jtag: $(HEX)
	@echo "JTAG programming chip-erases the device."
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(JTAG_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) -U flash:w:$(HEX):i
else
flash-jtag:
	@echo "Refusing JTAG programming: it chip-erases the device." >&2
	@echo "Re-run: make flash-jtag ALLOW_BOOTLOADER_ERASE=1" >&2
	@exit 1
endif

fuses-read:
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) \
		-U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h

fuses-jtag:
	$(call require_fuses,High fuse $(HFUSE_JTAG) enables JTAG and OCD. Analog A4-A7 become the JTAG port. The bootloader is not erased.)
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) \
		-U hfuse:w:$(HFUSE_JTAG):m

fuses-noboot:
	$(call require_fuses,High fuse $(HFUSE_NOBOOT) clears BOOTRST. Reset enters the application and the USB bootloader no longer runs.)
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) \
		-U hfuse:w:$(HFUSE_NOBOOT):m

fuses-jtag-noboot:
	$(call require_fuses,High fuse $(HFUSE_JTAG_NOBOOT) enables JTAG and OCD and clears BOOTRST.)
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) \
		-U hfuse:w:$(HFUSE_JTAG_NOBOOT):m

fuses-stock:
	$(call require_fuses,Restoring stock fuses L=$(LFUSE) H=$(HFUSE) E=$(EFUSE). This does not restore bootloader code.)
	$(AVRDUDE) -p $(AVRDUDE_MCU) -c $(ISP_PROGRAMMER) -P $(DEBUG_PORT) -B $(AVRDUDE_BITCLOCK) \
		-U lfuse:w:$(LFUSE):m -U hfuse:w:$(HFUSE):m -U efuse:w:$(EFUSE):m

debug-server: $(ELF)
	avarice -g -j $(DEBUG_PORT) --part $(MCU) -B $(JTAG_BITRATE) :$(GDB_PORT)

gdb: $(ELF)
	$(GDB) -n -x tools/gdbinit $(ELF)

clean:
	rm -rf build

help:
	@echo "Board: $(BOARD) ($(MCU), F_CPU=$(F_CPU))"
	@echo "  make                         build $(ELF)"
	@echo "  make BOARD=atmega1284p       build the 1284P template"
	@echo "  make DEBUG=1                 build with -Og"
	@echo "  make size                    print memory use"
	@echo "  make flash                   USB bootloader via $(USB_PROGRAMMER) on $(USB_PORT)"
	@echo "  make flash-isp ALLOW_BOOTLOADER_ERASE=1"
	@echo "  make flash-jtag ALLOW_BOOTLOADER_ERASE=1"
	@echo "  make fuses-read              read fuses over Dragon ISP"
	@echo "  make fuses-jtag ALLOW_FUSE_WRITE=1"
	@echo "  make fuses-noboot ALLOW_FUSE_WRITE=1"
	@echo "  make fuses-jtag-noboot ALLOW_FUSE_WRITE=1"
	@echo "  make fuses-stock ALLOW_FUSE_WRITE=1"
	@echo "  make debug-server            AVaRICE on :$(GDB_PORT), no flash write"
	@echo "  make gdb                     avr-gdb attached to that server"
	@echo "  make toolchain               print compiler, gdb, avrdude, avarice versions"
	@echo "  make clean"

define require_fuses
@if [ "$(FUSES_KNOWN)" != "1" ]; then \
	echo "This board file has no known-good fuse values. Read them and edit the board file first." >&2; \
	exit 1; \
fi
@if [ "$(ALLOW_FUSE_WRITE)" != "1" ]; then \
	echo "$(1)" >&2; \
	echo "Re-run with ALLOW_FUSE_WRITE=1. The low fuse is not changed by this target." >&2; \
	exit 1; \
fi
@echo "$(1)"
endef

-include $(DEP)
