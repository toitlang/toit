# RP2040 recovery and USB updates

This directory contains the native USB updater and its test application.
A separate [VM build](../../tests/hw/rp2040/README.md) uses the same updater.
The RP2040 build has no Wi-Fi transport. The RP2350 ROM partition/update
implementation cannot be used on RP2040.

Select the board variant before using the rig's UART. On W-2023, GP0/GP1
are connected to the onboard ESP8285, so the helper's GPIO4 connects to GP17.
The Pico's UART TX remains GP16 to helper GPIO34. The default board is `pico`.
The [build guide](../../docs/rp2040.md) describes Makefile targets and per-board
build directories.

The first installation needs BOOTSEL and a UF2 copy. Subsequent application
updates use USB CDC. The board-specific updater samples GP17 on W-2023, or GP1
on official Pico W (UART0 RX from ESP32 GPIO4),
after reset: holding it low while pulsing RUN enters recovery even if the
application's USB interface is broken. BOOTSEL is not wired in this rig.

## Build and first installation

Use the repository's pinned Pico SDK and picotool (see `tools/rp2350/setup.sh`):

```sh
CCACHE_DISABLE=1 cmake -S toolchains/rp2040 -B build/rp2040-recovery \
  -G Ninja -DCMAKE_BUILD_TYPE=MinSizeRel -DPICO_BOARD=pico_w_2023
CCACHE_DISABLE=1 cmake --build build/rp2040-recovery --parallel 6
bash tools/rp2040/tests/run.sh
python3 -m unittest discover -s tools/rp2040/tests -p 'test_*.py'
```

For the **initial, user-coordinated flash**, copy
`build/rp2040-recovery/toit-rp2040-recovery.uf2` to the Pico's `RPI-RP2` drive.
This image stays in the updater until an application is installed. Identify its
new `/dev/serial/by-id/` link before opening it. Its USB console prints
`RP2040-UPDATER 1 id=... app=0 size=0 crc=00000000`.

Do not copy the probe UF2 to the drive as a standalone firmware: the probe is
linked at `0x10020000` and needs the recovery loader and installed descriptor.

## Application updates

Install `pyserial` in the host Python environment, then use the observed Pico
serial link (the port below is a placeholder):

```sh
python3 tools/rp2040/upload.py --port /dev/serial/by-id/OBSERVED_PICO_LINK \
  --version 1 --expect 'RP2040-PROBE version=1 id={id}' \
  build/rp2040-recovery/toit-rp2040-probe.bin
```

Rebuild the probe with `-DTOIT_RP2040_PROBE_VERSION=2` and use `--version 2`
and the corresponding `--expect` line for the next upload. Add
`--request-update` when the probe or VM is running; selecting 1200 baud on USB
requests recovery without consuming application input. The native diagnostic
also retains its explicit `update` command. The uploader validates the binary's link address, sends
CRC-checked blocks, commits, reconnects using the same port, and checks the
installed size/version/CRC and, with `--expect`, application startup.

The probe's `hang` command disables interrupts and stops feeding the watchdog.
Within eight seconds the loader should return in recovery. To recover through
the ESP32 independently of application behavior, run `recovery-esp32.toit` on
the connected ESP32. It pulls GPIO4 and GPIO21 low, releases RUN, then releases
GPIO4. Both pins use open drain. Do not run a UART container on GPIO4 at the
same time. The script never touches BOOTSEL/ESP32 GPIO16.

## Flash layout and failure behavior

| Flash offset | Size | Purpose |
| --- | --- | --- |
| `0x000000` | 64 KiB | Recovery loader; excluded from application update writes |
| `0x010000` | 4 KiB | Installed application descriptor |
| `0x011000` | 4 KiB | Committed staged update descriptor |
| `0x012000` | 56 KiB | Toit flash registry; preserved by application updates |
| `0x020000` | 960 KiB | Executable application, linked at `0x10020000` |
| `0x110000` | 960 KiB | Staged application |

Downloading leaves the installed application intact. Commit verifies the whole
staged image and writes its descriptor last. On reset the loader invalidates
the installed descriptor, copies and verifies the staged image, writes the new
installed descriptor, and finally clears the pending descriptor. A reset during
copying repeats the copy from the intact staging area. Every boot checks the
application CRC and initial vectors before jumping to it.

This provides recovery and resumable installation, **not automatic rollback to
the previous application**. A watchdog failure stays in the loader, where the
host can upload a known-good application. CRC detects accidental corruption;
images are not authenticated. The loader is protected by update bounds, not a
hardware permission boundary against arbitrary application code. Updating the
loader itself still requires a coordinated initial-flash procedure.

Applications must use this link layout, leave core 1 unused during flash
operations, and feed the watchdog inherited from the loader. These are native
bring-up routines; no Toit primitive blocks waiting for an upload.

## Validation

The native probe's `bootsel` command enters the RP2040 ROM USB bootloader
without a button press or GPIO output. It does not write flash. In this mode,
use picotool with the verified ROM serial identity or USB bus/address; the USB
identity differs from the running application's CDC identity. `picotool reboot`
returns to the existing loader and application. Replacing the loader is a
separate flash operation; save and verify a full backup first.

Recovery protocol replies wait for USB transmit space for up to five seconds,
feeding the watchdog while waiting. An update session is canceled on CDC
disconnect or after ten seconds without a completed command; incomplete
command framing is discarded. A complete data block must arrive within five
seconds. Uncommitted staged bytes never replace the installed image. A commit
is durable even if its final acknowledgement is lost; query the installed
version, size and CRC before interpreting a timeout as an unchanged device.

The input-only wiring probe accepts `pins` to release the tested header GPIOs, and
`pull PIN MODE` to enable one weak pull (`0`: none, `1`: up, `2`: down).
It reports both the sampled value and pad/control/SIO registers, so a software
override can be distinguished from a pad-level reading. Radio pads, including
GP0/GP1 on W-2023, are excluded.
Run `wiring-esp32.toit` as the observer before `check-wiring.py`; neither side
enables an output driver. `rx-pull-esp32.toit` reverses the weak stimulus for
the UART RX wire. `run-pull-esp32.toit` tests RUN using only ESP32 input pulls.
Validate the wiring before running the open-drain recovery helper.

The existing Pico W-2023 rig has the following signal connections. These are
GPIO numbers, not header positions. The UART RX wire was moved from GP1 to
GP17 to avoid the onboard ESP8285; the other connections remain in place.

| Pico W-2023 | Helper ESP32 |
| --- | --- |
| GP4 | GPIO19 |
| GP5 | GPIO27 |
| GP6 | GPIO18 |
| GP7 | GPIO23 |
| GP8 | GPIO13 |
| GP9 | GPIO14 |
| GP10 | GPIO32 |
| GP11 | GPIO33 |
| GP16 (UART TX) | GPIO34 |
| GP17 (UART RX/recovery) | GPIO4 |
| GP21 | GPIO35 |
| GP22 | GPIO22 |
| GP26 | GPIO25 |
| GP27 | GPIO26 |
| RUN | GPIO21 |
| GND | GND |

The external SPI/I2C/ADC fixtures reuse GP4–GP7 and GP26 from this map; they
do not require additional wires. Their input-only gate checks the selected
connections again before enabling peripheral outputs.

`reset-esp32.toit` only pulses the verified RUN wire using an open-drain GPIO.
A USB host polling the loader with `hello` during startup can then keep it in
recovery, including with the older GP1 loader on W-2023. Use a Jaguar SDK matching
the helper's installed firmware; rebuilding the RP2040 host tools from a newer
commit can otherwise make the helper reject the SDK version before pulsing RUN.

The host test compiles the actual `update.c` against simulated NOR flash and
cuts power before, during and after every erase/program operation in a
two-sector update. It checks recovery, a subsequent successful upload, loader
preservation, bad ranges and corrupt images. AddressSanitizer and
UndefinedBehaviorSanitizer are enabled. The Python tests cover fragmented
serial responses, block framing, device rejection, timeouts and link-address
validation.

Hardware validation must additionally cover initial enumeration, version 1 to
version 2 updates, watchdog recovery, recovery through ESP32 RUN/GP1, and a
reset during installation. Host tests alone do not establish these results.
