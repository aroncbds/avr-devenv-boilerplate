# Stepper interface

AVR operator interface for an HBS86H stepper driver, aimed at semi-automatic motion control.

This tree is the C99 baseline: an Arduino Mega 2560 (ATmega2560 at 16 MHz), avr-libc, avr-gcc, FreeRTOS, USB bootloader flashing, and AVR Dragon ISP/JTAG for the point where the bootloader comes off. A second board file is the starting point for an ATmega1284P or another AVR.

## Layout

```
Makefile                  board selection, build, flash, fuses, debug
boards/atmega2560.mk      Arduino Mega 2560
boards/atmega1284p.mk     bare 1284P template
include/FreeRTOSConfig.h  kernel and tick-source settings
src/                      application (heartbeat, USART0 console, LED)
third_party/              FreeRTOS-Kernel V11.3.2 plus one local patch
.devcontainer/            Debian bookworm image with the AVR toolchain
tools/                    fetch script, gdbinit, Dragon udev rule
```

`make help` lists the targets.

## Dev container

Reopen the folder in the dev container. The image is Debian bookworm and installs the distribution AVR toolchain: avr-gcc 5.4.0, binutils-avr, avr-libc 2.0.0, avrdude 7.1, AVaRICE 2.14, and avr-gdb. The first start runs `make all`.

`make` writes `build/atmega2560/stepper-interface.hex`. `build/stepper-interface.elf` is a symlink to whichever board was linked last.

## Firmware

`src/main.c` starts FreeRTOS and a heartbeat task. On the Mega it toggles the "L" LED (PB7, Arduino digital 13) every 500 ms and writes a line to USART0 at 115200 8N1:

```
heartbeat 12 stack 280
```

USART0 is the USB-serial bridge on the Mega (PE0/PE1, Arduino pins 0 and 1). On a 1284P the same registers are PD0/PD1. `stack` is the FreeRTOS high-water mark in bytes from `uxTaskGetStackHighWaterMark2`. This port's `UBaseType_t` is 8 bits, so the plain high-water API saturates at 255; the `2` variant does not.

An assert, stack overflow, or failed allocation disables the watchdog and blinks the LED quickly.

The scheduler tick is Timer0 in CTC mode at 100 Hz (`configAVR_USE_TIMER0_TICK` in `include/FreeRTOSConfig.h`). The port's divide-by-1024 makes that rate land on about 100.2 Hz at 16 MHz, and it leaves the watchdog off so a fault cannot lock the Mega's USB bootloader. Timer1, Timer3, Timer4, and Timer5 stay free for step pulses. Step generation for the HBS86H belongs in a 16-bit timer ISR, not in a task delay.

Set `configAVR_USE_TIMER0_TICK` to 0 to use the enhanced watchdog interrupt (about 16 ms, `WDTO_15MS`) and free Timer0 as well. That can wedge an old Mega bootloader if the CPU hangs with the watchdog armed; keep the Dragon in reach before switching. Run `make clean` after changing it. The build prints `Timer0 used for scheduler` or the watchdog equivalent.

Stack sizes in this port are bytes (`StackType_t` is `uint8_t`). The Mega heap is 4096 bytes inside the SRAM total that `make` prints. Task functions on the 2560 are placed in `.lowtext`, which the avr6 linker script gathers at the start of flash, because the port stores a 16-bit task entry point.

## USB flashing

The Mega's bootloader speaks stk500v2. `make flash` calls avrdude's `wiring` programmer at 115200 baud and does not erase the bootloader. The link reserves the top 8 KiB (text region of 253952 bytes). The port is `/dev/ttyACM0` when that node exists (official Mega, 16U2) and `/dev/ttyUSB0` otherwise (CH340 clones). Override with `USB_PORT=`.

On WSL2, attach the board to the same distro that runs Docker:

```sh
usbipd list
usbipd bind --busid <id>
usbipd attach --wsl --busid <id>
```

Confirm the node there (`ls /dev/ttyUSB0 /dev/ttyACM0`). The dev container does not share WSL's `/dev`. It bind-mounts that directory at `/dev/host-dev` and links `ttyACM0`, `ttyUSB0`, and `bus/usb` into its own `/dev`. Rebuild the container once so those mounts exist. A board plugged in afterward shows up through the links. Attaching the USB device to a different WSL distro than the one running Docker leaves it invisible here.

## Another AVR

```sh
make BOARD=atmega1284p
make BOARD=atmega1284p F_CPU=20000000UL
```

Copy `boards/atmega1284p.mk` for the next part. Set `F_CPU` to the crystal you actually fit, or baud rates and timer ticks are wrong. The 1284P file leaves the LED off, leaves USB programming unset, and does not define fuses. `make flash-isp` is the programming path. Fill in the fuse bytes from `make fuses-read` before any fuse target will run.

## AVR Dragon, ISP

The Dragon ISP 6-pin plug matches the Mega ICSP header. Pin 1 is MISO on both.

```sh
make fuses-read
```

reads the three fuse bytes over ISP and writes nothing.

```sh
make flash-isp ALLOW_BOOTLOADER_ERASE=1
```

chip-erases the part, which deletes the USB bootloader. The application is linked at address 0 either way. On a stock Mega the high fuse still has BOOTRST programmed, so reset jumps into the now-empty boot section and both USB upload and the application stay silent until one of these:

```sh
make fuses-noboot ALLOW_FUSE_WRITE=1          # high fuse 0xD9, reset enters the application
make fuses-stock ALLOW_FUSE_WRITE=1           # back to the Arduino Mega fuse bytes
```

`fuses-stock` does not restore bootloader code. The Arduino AVR boards package ships that image as `stk500boot_v2_mega2560.hex`. Program it with avrdude after the stock fuses are back, then `make flash` works again.

`fuses-stock` is the only target that writes the low fuse. A wrong low fuse selects the wrong clock, and ISP then needs an external clock or the Dragon's high-voltage parallel mode. This baseline does not automate high-voltage programming.

## AVR Dragon, JTAG

Stock Mega high fuse `0xD8` has JTAG and on-chip debug switched off. Fuse bits are active-low: a programmed bit is 0.

```sh
make fuses-jtag ALLOW_FUSE_WRITE=1
```

writes high fuse `0x18`. That enables OCD and JTAG, leaves SPI programming enabled, and leaves the bootloader in place, so `make flash` still works. Analog A4–A7 become the JTAG port:

| Signal | Mega pin |
| --- | --- |
| TCK | PF4, analog A4 |
| TMS | PF5, analog A5 |
| TDO | PF6, analog A6 |
| TDI | PF7, analog A7 |
| nSRST | RESET |

Dragon 10-pin JTAG, looking at the plug: 1 TCK, 2 GND, 3 TDO, 4 VTref, 5 TMS, 6 nSRST, 7 VCC, 9 TDI, 10 GND. Pin 8 (nTRST) is not used on this AVR. VTref and VCC go to 5 V.

`tools/99-avr-dragon.rules` is the udev rule for USB id `03eb:2107`. On WSL the usbip node is often root-owned; the container runs as root, so the rule matters on a native Linux host.

Debug does not erase flash. In one terminal:

```sh
make debug-server
```

In another:

```sh
make gdb
```

`tools/gdbinit` connects to `:4242`, allows 4 hardware breakpoints and 2 watchpoints, and does not issue `load`. With BOOTRST still set, the bootloader runs after reset; `break main` then `continue` stops in the application. The launch configuration "AVR Dragon JTAG" attaches to the same port and expects `make debug-server` to be running already.

When ISP is the only programming path and the bootloader should stay out of reset:

```sh
make fuses-jtag-noboot ALLOW_FUSE_WRITE=1     # high fuse 0x19
```

On the 1284P the JTAG pins are PC2 (TCK), PC3 (TMS), PC4 (TDO), and PC5 (TDI). That board file will not write fuses until you put measured values in it.

## FreeRTOS

`third_party/freertos.tag` pins FreeRTOS-Kernel V11.3.2. `tools/fetch-deps.sh` clones it if `tasks.c` is missing and applies `tools/freertos-timer0.patch`. The patch is the only change to the kernel: `configAVR_USE_TIMER0_TICK` can select Timer0. Leaving the macro unset keeps the upstream watchdog choice.
