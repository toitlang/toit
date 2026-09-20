# WeAct RP2350B bring-up rig

The target is a **WeAct Studio RP2350B Core Board**. A classic **ESP32
DevKitC V4** provides peripheral test signals, DAC outputs, and BOOT/RUN
control. The Toit VM, garbage collection, persistent storage, containers, and
USB OTA updates run on the board. Peripheral results and remaining gaps are
recorded below.

The ESP32 mapping assumes a **WROOM module with GPIO16/17 available**, not a
WROVER module using those pins for PSRAM. All pin numbers below are **GPIO
numbers, not physical header positions**. If the ESP32 assignments change,
update this table and [`wiring.toit`](../tools/rp2350/wiring.toit) before using it.

## Device identification

Read from udev and USB sysfs on 2026-09-19 without opening either serial port
or resetting either board. The user identified `/dev/ttyUSB4` as this rig's
ESP32 and confirmed that the WeAct enumerates when manually put into BOOTSEL.
The WeAct was running MicroPython during this inspection.

| Identity | ESP32 helper | WeAct target, current MicroPython firmware |
| --- | --- | --- |
| USB device | Silicon Labs CP2102N USB-to-UART bridge | MicroPython Board in FS mode |
| VID:PID | `10c4:ea60` | `2e8a:0005` |
| USB serial | `d237166db89bea11bb5c10bfec257580` | `dc67867c6256ed2b` |
| Observed tty (not persistent) | `/dev/ttyUSB4` | `/dev/ttyACM2` |
| Host USB controller | PCI `0000:00:14.0` | PCI `0000:00:14.0` |
| Physical USB port chain | `1.3` | `4.3.2` |
| Observed sysfs USB node | `1-1.3` | `1-4.3.2` |

Use these **by-id paths**, not numbered tty paths:

```sh
ESP32_PORT=/dev/serial/by-id/usb-Silicon_Labs_CP2102N_USB_to_UART_Bridge_Controller_d237166db89bea11bb5c10bfec257580-if00-port0
RP2350_PORT=/dev/serial/by-id/usb-MicroPython_Board_in_FS_mode_dc67867c6256ed2b-if00

# Resolve the current tty assignments and inspect identities without opening them.
readlink -e "$ESP32_PORT"
udevadm info --query=property --name="$ESP32_PORT"
readlink -e "$RP2350_PORT"
udevadm info --query=property --name="$RP2350_PORT"
```

The ESP32 path identifies its USB-to-UART bridge and survives host reboot,
tty reordering, moving USB ports, and changing the ESP32 application firmware.
Do not substitute another CP2102N just because it has the same VID:PID.

The corresponding **by-path fallbacks** identify the current USB sockets and
hub arrangement. They remain useful across tty reordering but change if the
boards are moved to different sockets or hubs:

```text
ESP32: /dev/serial/by-path/pci-0000:00:14.0-usb-0:1.3:1.0-port0
WeAct: /dev/serial/by-path/pci-0000:00:14.0-usb-0:4.3.2:1.0
```

The RP2350's by-id path above is **firmware-dependent**. In BOOTSEL it becomes
a different USB device (normally `2e8a:000f`) and does not expose this serial
port. Its USB port chain remains the same while the cable stays connected.
After entering BOOTSEL, rediscover the device at that location and read its
bootloader serial before using `picotool --ser`. Do not assume it matches
the MicroPython serial or reuse a cached USB bus/address: addresses change
on re-enumeration.

The first flash confirmed these additional identities:

| Mode | VID:PID | USB serial | Interface |
| --- | --- | --- | --- |
| ROM BOOTSEL | `2e8a:000f` | `DC67867C6256ED2B` | Mass storage (`RP2350`) and picoboot |
| Native SDK bring-up | `2e8a:0009` | `DC67867C6256ED2B` | CDC console and USB reset |

The current application console is:

```text
/dev/serial/by-id/usb-Raspberry_Pi_Pico_DC67867C6256ED2B-if00
```

A USB disconnect/reconnect alone does not establish BOOTSEL entry. Check the
product ID and the mass-storage interface, not just the dmesg notification.

Resetting and monitoring the identified ESP32 serial port established its
Jaguar identity as **`opposite-singer`**, device ID
`c5ff57f7-eec1-4c74-8ead-31a01ad99fcd`, SDK `v2.0.0-alpha.199`.
The [firmware update log](../tests/hw/rp2350/results/2026-09-19-esp32-alpha199-update.log)
records the upgrade; its identity and network settings were preserved.
Its observed DHCP address is `http://192.168.77.95:9000`; rediscover the name
rather than assuming that address persists. Its chip MAC was not queried.

## Connections

| WeAct RP2350B | ESP32 GPIO | Series resistor | Purpose |
| --- | --- | --- | --- |
| GND | GND | None | Common ground |
| GP16 | 34 | 220 ohm | UART0: RP TX to ESP RX |
| GP1 | 4 | 220 ohm | UART0: RP RX from ESP TX |
| GP4 | 19 | 220 ohm | SPI0 MISO / I2C0 SDA |
| GP5 | 27 | 220 ohm | SPI0 CS / I2C0 SCL |
| GP6 | 18 | 220 ohm | SPI0 clock |
| GP7 | 23 | 220 ohm | SPI0 MOSI |
| GP8 | 13 | 220 ohm | UART1 TX / SPI1 MISO |
| GP9 | 14 | 220 ohm | UART1 RX / SPI1 CS |
| GP10 | 32 | 220 ohm | I2C1 SDA / SPI1 clock / UART1 CTS |
| GP11 | 33 | 220 ohm | I2C1 SCL / SPI1 MOSI / UART1 RTS |
| GP32 | 22 | 220 ohm | Bidirectional GPIO, interrupts, PWM/PIO |
| GP33 | 17 | 1 Mohm | Weak high/low stimulus for internal-pull tests |
| GP33 (same target pin) | 35 | 220 ohm | Independent observation of the pull-test node |
| GP40 / ADC0 | 25 / DAC | **4 kohm** | Analog stimulus |
| GP41 / ADC1 | 26 / DAC | **10 kohm** | Second analog stimulus |
| RUN header pin | 21 | 220 ohm | Reset, ESP open-drain output |
| BOOT button's non-ground contact | 16 | 220 ohm | Bootloader entry, ESP open-drain output |

SPI signal names assume the RP2350 is the controller. Shared peripheral
functions run in separate tests; unused drivers must release their pins.
ESP34/35 are input-only and have no internal pull resistors. The selected
ESP pins avoid strapping pins 0, 2, 5, 12, and 15, and leave ESP UART0 free
for its USB-to-serial console.

**RP GP16 and ESP GPIO16 are different connections:** RP GP16 is UART0 TX;
ESP GPIO16 controls BOOT. RP GP0 is deliberately unused by the harness because
WeAct connects it to the optional secondary flash/PSRAM chip-select.
GP31 is unused after moving ESP35 to observe GP33.

Power both boards through their own USB connections and connect GND directly.
Do not join their regulated 3.3 V outputs. Keep both boards powered while
driving test signals. SWD is not wired in this setup.

### I2C pull-ups

Provide removable **4.7 kohm pull-ups** from each of RP GP4, GP5, GP10, and GP11
to the **WeAct's 3.3 V rail**, on the RP side of the series resistors. These
are separate from the 220 ohm series resistors. Remove them when testing a
pin's internal pulls; keep them for ordinary I2C operation.

### Internal-pull test

```text
ESP17 output --- 1 Mohm ---+--- RP GP33
                         |
ESP35 input ---- 220 ohm -+
```

No other external pull or direct ESP output connection belongs on GP33.
ESP35 observes the node independently of the RP2350's own reading.

| ESP17 output | RP GP33 configuration | Expected ESP35 reading after settling |
| --- | --- | --- |
| Low | Internal pull-up | High |
| High | Internal pull-down | Low |
| Low | Both pulls disabled | Low |
| High | Both pulls disabled | High |

RP2350 A2 silicon has the E9 input-leakage erratum, which can defeat weak
pull-downs. Record the silicon revision before treating such failures as
driver bugs. The B in RP2350B identifies the package, not the silicon revision.

### ADC

The 4 kohm and 10 kohm resistors replace the originally proposed 1 kohm series
resistors. They are **not voltage dividers**. GP40/41 are dedicated to ADC
testing in this rig. Disable their digital input buffers and internal pulls,
allow the DAC output to settle, and start with slow DC/staircase measurements.
Keep the analog input within the target's ADC range. The ESP32 DAC provides
an 8-bit stimulus, not a precision voltage reference. Higher sampling rates
require separate validation of settling and source impedance.

### BOOT and RUN

On the published WeAct schematic, SW1 is BOOT: pins 1/2 are ground and pins
3/4 carry `USB_BOOT`. R12 (1 kohm) connects `USB_BOOT` to QSPI chip-select.
The soldered control wire goes to the **non-ground button contact**, on the
button side of R12. Identify the physical contact with a continuity check
while unpowered; schematic pin numbers do not establish its board orientation.

Both ESP outputs must be open-drain, initially released, with no internal
pulls: **drive low or release; never actively drive high**. No transistor is
required for this wiring with both boards powered. RST duplicates the RUN
header connection, and KEY is a separate user button on RP GP23; neither
button needs another wire. The WeAct's user LED is on RP GP25.

Enter the USB bootloader as follows:

1. Pull BOOT low, matching a held physical BOOT button.
2. Pulse RUN low.
3. Release RUN while holding BOOT low.
4. Allow the boot ROM to sample BOOT, then release BOOT.
5. Check USB enumeration before attempting a flash.

The order matters on this rig: asserting RUN before BOOT returned to the
application, while asserting BOOT before pulsing RUN entered the ROM's
`2e8a:000f` mass-storage mode. Both sequences produced a USB reconnect, so
always check the resulting device identity. The physical button is labelled
**BOOT**; **BOOTSEL** names the ROM flashing mode.

## Host software

Run from the repository root:

```sh
bash tools/rp2350/setup.sh
export PICO_SDK_PATH="$PWD/third_party/pico-sdk"
export PATH="$PWD/.cache/rp2350/install/bin:$PATH"
```

The setup script builds USB-enabled **picotool 2.3.1** and installs it under
`.cache/rp2350/install`. Host tool sources and build products stay in the ignored
`.cache/rp2350` directory. The SDK is a pinned Git submodule at
`third_party/pico-sdk`, using [Toit's fork](https://github.com/toitlang/pico-sdk),
branch `toit-2.3.1`. The fork adds a low-power reset fix to upstream 2.3.1:
watchdog resets clear persistent data even after an earlier timer wakeup.
Setup preserves an existing SDK checkout so
local SDK patches are not discarded. It initializes TinyUSB and mbedTLS.
It does not flash a device or install system files.

The compiler is **not pinned or forked**. The SDK selects an installed Arm GNU
`arm-none-eabi` toolchain. Override it with `PICO_TOOLCHAIN_PATH` through CMake
when needed. The tested host compiler is `arm-none-eabi-gcc 16.2.0` with newlib
and the target C++ standard library.

Pinned sources:

| Component | Release | Commit |
| --- | --- | --- |
| picotool | 2.3.1 | `2041936441b48a3cc53ae3da9e805229fe8f4e18` |
| Pico SDK | 2.3.1 + Toit reset fix | `02df2f95f858960d5f6971324be864bb9fb05be0` |

The SDK's pinned mbedTLS and TinyUSB submodules are downloaded as well. Host
prerequisites are Git, C/C++ compilers, CMake, Ninja, pkg-config, and libusb
development files. An `arm-none-eabi` compiler is needed to build target
firmware, but not for this picotool build.

The SDK board name is `weact_studio_rp2350b_core`; start with the Arm platform
`rp2350-arm-s`. Its default UART pins differ from this rig, so target firmware
must explicitly select **UART0 TX=16, RX=1**. The native target produces ELF,
BIN, and UF2 images:

```sh
make rp2350-setup
make rp2350-bringup
# Optional compiler selection (use a new build directory when changing compiler):
make rp2350-bringup RP2350_BUILD=build/rp2350-custom \
  RP2350_CMAKE_FLAGS='-DPICO_TOOLCHAIN_PATH=/path/to/arm-toolchain'
```

Output: `build/rp2350/toit-rp2350-bringup.{elf,bin,uf2}`. This standalone SDK
project lives in `toolchains/rp2350`, following the ESP-IDF project layout.
It does not pull in EC618/ESP32 firmware builds or the host Toit compiler.
The target blinks GP25, prints its board ID and increasing tick count over
USB, and echoes raw bytes on UART0 at 115200 8N1 (TX GP16, RX GP1).
USB reset support includes the SDK's 1200-baud reset-to-BOOTSEL mechanism.
This is native hardware validation, **not a running Toit VM**.

After flashing, test both UART directions with:

```sh
jag run tools/rp2350/uart-smoke-esp32.toit --device opposite-singer
```

The helper requires exact byte-for-byte echo for 4096 bytes, including all
256 byte values. Read its console output for PASS; successful `jag run`
only establishes that the helper was uploaded.

The current ESP32 UART driver logs a pull-up warning for GPIO34, which has no
internal pull-up. The hardware echo test nevertheless passed. This does not
require changing the wiring; it is a helper-driver diagnostic.

### Linux USB permissions

If picotool reports insufficient access, install its supplied udev rules:

```sh
sudo install -m 0644 .cache/rp2350/src/picotool/udev/60-picotool.rules \
  /etc/udev/rules.d/60-picotool.rules
sudo udevadm control --reload-rules
```

Reconnect USB or re-enter BOOTSEL afterward. The upstream rules grant access
to the active local user via `uaccess` and to the `plugdev` group where present.
An unattended/headless runner may need an administrator to grant that runner
access explicitly. RP2350's default USB bootloader ID is `2e8a:000f`.

## Entering BOOTSEL with the ESP32

[`bootloader-esp32.toit`](../tools/rp2350/bootloader-esp32.toit) is a one-shot
helper using ESP16 for BOOT and ESP21 for RUN. It starts with both released,
pulses the pins in the order above, and releases/closes them on exit. Its
one-second BOOT hold is a starting delay; the host must still confirm that
the USB bootloader appeared.

[`reset-esp32.toit`](../tools/rp2350/reset-esp32.toit) performs a normal
application reset without asserting BOOT. It holds RUN low for 100 ms, releases
RUN, and closes the open-drain pin before exiting:

```sh
jag run tools/rp2350/reset-esp32.toit --device opposite-singer
```

Use this helper when a test needs a normal ROM boot, including checking that a
validated OTA image remains confirmed after reset. Confirm the application USB
identity after it reconnects. As with the BOOTSEL helper, stop any program that
owns ESP GPIO21 before running it.

For troubleshooting, `diagnose-control-esp32.toit` also reads the ESP32 ends
of the control lines. `hold-control-esp32.toit` holds BOOT and RUN low for five
minutes for multimeter measurements, then releases them in bootloader-entry
order. The latter intentionally keeps the target disconnected while RUN is low.

The ESP32 must already run compatible Jaguar firmware. Identify the correct
helper device explicitly; do not reuse the EC618 rig's name without checking.
Stop any helper container that owns GPIO16/21 before running this program.
`jag run` replaces the current Jaguar run program.

```sh
jag run tools/rp2350/bootloader-esp32.toit --device opposite-singer

# On the host, after the helper has run:
lsusb -d 2e8a:000f
.cache/rp2350/install/bin/picotool info -a --ser DC67867C6256ED2B
```

Manual fallback: hold the physical BOOT button, press and release RST, then
release BOOT. No separate debug probe is needed.

## Flashing

With the target in BOOTSEL and a firmware UF2 built for this board:

```sh
.cache/rp2350/install/bin/picotool load -v -x path/to/firmware.uf2 \
  --ser DC67867C6256ED2B

# Equivalent Make target for the built native image (requires USB permissions):
make rp2350-flash-bringup RP2350_SERIAL=DC67867C6256ED2B
```

`-v` verifies the write and `-x` starts the firmware. If multiple bootloader
devices are present, select this board using the USB bus/address or serial
options shown by `picotool help load`; never select another rig by guessing.
Run `picotool info -a` first to check the device identity.

The bring-up firmware includes compatible USB reset support. Software-only
updates can add `RP2350_FLASH_FLAGS=-f` to the Make command. The `-f` request
requires responding firmware; hardware BOOT/RUN control remains the recovery
path for hangs. A firmware flash overwrites the target's existing image.

### UF2 mass-storage fallback on this host

The first flashes used the standard UF2 drive because this user has no raw
USB write permission for picotool and `sudo -n` requires a password. A mounted
UF2 drive does not require picotool's USB access. With the identified target
in BOOTSEL, wait for its block device to enumerate, then:

```sh
lsusb -d 2e8a:000f
lsblk -o NAME,TRAN,LABEL,MOUNTPOINTS
# Confirm the RP2350 block device belongs to the recorded USB port/serial.
udevadm info --query=path --name=/dev/disk/by-label/RP2350
udisksctl mount -b /dev/disk/by-label/RP2350 --no-user-interaction
cp build/rp2350/toit-rp2350-bringup.uf2 /run/media/flo/RP2350/
```

The mount path is host-dependent; use the path returned by `udisksctl`.
Do not identify the target by volume label alone when more than one RP-series
board is connected. The ROM automatically starts the completed UF2 image.
Validate its USB heartbeat afterward. This confirms execution; it is not a
picotool read-back verification.

## Preparation status (2026-09-19)

- Built picotool 2.3.1 against the pinned SDK submodule and built the native
  Arm Secure bring-up target with the installed GNU Arm compiler.
- Flashed an initial USB heartbeat, then the repo-built USB/UART image through
  UF2 mass storage. Both ran and printed increasing ticks with the correct ID.
- The ESP32 helpers pass `toit analyze -Werror`. Jaguar identity is confirmed.
- RUN control makes the RP2350 disconnect. The user measured both WeAct RUN
  and the wired BOOT contact close to 0 V while both were asserted by the ESP32.
- Confirmed automatic BOOT entry after correcting the helper's sequence to
  assert BOOT before pulsing RUN: `2e8a:000f`, interfaces `08` (mass storage)
  and `ff` (picoboot), volume `RP2350`.
- UART0 passed 4096 bytes of exact binary echo at 115200 8N1, including every
  byte value: ESP4 -> GP1 -> GP16 -> ESP34.
- Raw USB picotool permission remains pending. UF2 flashing through the mounted
  drive works; read-back verification through picotool has not been performed.
- No system udev rules were installed. MicroPython has been replaced by the
  native validation image.

## References

- [WeAct schematic](https://github.com/WeActStudio/WeActStudio.RP2350BCoreBoard/blob/main/HDK/RP2350B_SCH.pdf)
- [WeAct pinout](https://github.com/WeActStudio/WeActStudio.RP2350BCoreBoard/blob/main/HDK/RP2350B_PINOUT.png)
- [RP2350 datasheet and errata](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [picotool 2.3.1](https://github.com/raspberrypi/picotool/tree/2.3.1)
- [Pico SDK 2.3.1](https://github.com/raspberrypi/pico-sdk/tree/2.3.1)

## Native full-rig result (2026-09-19)

The native electrical endpoint is [`rig_test.c`](../toolchains/rp2350/rig_test.c),
built as `toit-rp2350-rig-test` for `rp2350-arm-s` with the pinned Pico SDK
2.3.1. The ESP32 controller is
[`rig-test-esp32.toit`](../tests/hw/rp2350/rig-test-esp32.toit). The flashed
69,120-byte UF2 had SHA-256
`bcde0a7ba6ef30fc2ad84c9c640a9a2e19e3cc0dc0922757ca9ecce09c149357`.
The RP2350 reported silicon revision 3, so the A2 E9 weak-pull exception did
not apply.

Build and run the same test with:

```sh
cmake --build build/rp2350 --target toit-rp2350-rig-test
jag run tools/rp2350/bootloader-esp32.toit --device opposite-singer
# Verify USB 2e8a:000f and serial DC67867C6256ED2B, then mount the RP2350 drive.
cp build/rp2350/toit-rp2350-rig-test.uf2 /run/media/flo/RP2350/
# Capture the helper's 115200-baud console using its stable CP2102N by-id path.
jag run tests/hw/rp2350/rig-test-esp32.toit --device opposite-singer
```

The exact captured verdicts and ADC samples are stored in
[`2026-09-19-native-rig.log`](../tests/hw/rp2350/results/2026-09-19-native-rig.log).
The following connections passed their stated tests:

- UART target TX GP16 to ESP34 and target RX GP1 from ESP4, followed by an
  exact 4,096-byte binary echo.
- GP4/ESP19, GP5/ESP27, GP6/ESP18, GP7/ESP23, GP8/ESP13, GP9/ESP14,
  GP10/ESP32, GP11/ESP33, and GP32/ESP22 in both directions at low and high.
- GP33 weak-low and weak-high stimulus from ESP17 through 1 Mohm, internal
  pull-up and pull-down observed independently at ESP35, and RP GP33 output
  low/high observed at ESP35.
- GP41 ADC1 from ESP26 DAC through 10 kohm. Its raw staircase was
  `319, 979, 1883, 2787, 3460` for DAC settings
  `0.2, 0.8, 1.6, 2.4, 3.0 V`.
- RUN open-drain reset and subsequent `2e8a:0009` application re-enumeration.
- BOOT-before-RUN entry into ROM USB `2e8a:000f`, with the expected serial and
  mass-storage volume.

The GP40/ESP25 analog path failed. GP40 stayed at raw values
`918, 918, 919, 918, 919` across the same five DAC settings. A follow-up drove
ESP25 as a push-pull digital output through the same 4 kohm connection; GP40
still read 921 when driven low and 919 when driven high. This excludes a
failure limited to DAC mode. The user subsequently found this wire on GP42
and moved it to GP40. The Toit ADC test then passed on both GP40 and GP41,
as recorded below; the original failing transcript is retained for history.

## Toit VM UART result (2026-09-19)

The RP2350 UART driver and event source passed the hardware test on UART0 with
TX GP16 connected to ESP34 and RX GP1 connected to ESP4. Peripheral pins use
plain GP numbers: GPx is passed as integer `x`, deprecated `gpio.Pin` objects
are rejected, and `-1` is accepted only for an optional disconnected pin. The
driver validates each pin's UART controller and signal role and reserves pins
through the shared GPIO pool.

The test passed exact echoes of 1, 31, 256, and 4,096 bytes at an actual baud
rate of 115,207, a 4,096-byte echo at 921,658 baud, and a 257-byte echo at
9,600 baud. It also passed receive-buffer overflow accounting, retained-prefix
behavior, post-overflow recovery, controller and pin reservation checks, and
clean VM teardown. These test points cover actual baud rates from 9,600 through
921,658. Hardware RTS/CTS pin-role validation passed with RTS GP19 and CTS
GP18; that flow-control pair was not physically wired for this run.

RS485 half-duplex mode, transmitted break, and 1.5 stop bits are unsupported.
The implementation reports `UNIMPLEMENTED` for those configurations instead of
silently approximating them. IrDA mode is also unsupported and currently reports
`INVALID_ARGUMENT`. The exercised sources are
the [UART resource](../src/resources/uart_rp2350.cc),
[event-source header](../src/event_sources/uart_rp2350.h), and
[event-source implementation](../src/event_sources/uart_rp2350.cc); the
target and rig programs are
[`uart-rp2350.toit`](../tests/hw/rp2350/uart-rp2350.toit) and
[`uart-esp32.toit`](../tests/hw/rp2350/uart-esp32.toit).

## Toit VM I2C result (2026-09-19)

The RP2350 controller driver accepts numeric GP identifiers only and shares
pin ownership with GPIO and the other peripheral drivers. It supports both
controllers, 7-bit addresses, controller frequencies through 1 MHz, combined
write/read transactions, configurable clock-stretch deadlines, and optional
ACK checking. GP4/5 and GP10/11 are the rig's primary I2C0 and I2C1 pairs.
The default clock-stretch timeout is 100 ms. Ten-bit addresses are supported
by targets, but not by the controller API.

The self-contained contract test passed argument and mux validation, numeric
pin enforcement, simultaneous controller reservation, GPIO ownership, child
lifecycle, and close/reopen checks. The shared-event stress test then passed
256 absent-address NACK transfers on each controller while GPIO interrupts,
UART writes, and timers were active. It repeated bus and device teardown and
ended with a clean VM shutdown. See
[`2026-09-19-i2c-contract.log`](../tests/hw/rp2350/results/2026-09-19-i2c-contract.log)
and
[`2026-09-19-event-stress.log`](../tests/hw/rp2350/results/2026-09-19-event-stress.log).

After updating the ESP32 to alpha.199, the
[paired hardware test](../tests/hw/rp2350/results/2026-09-19-i2c-alpha199-baseline-v36.log)
passed both controllers at 100 kHz: reads and combined write/read operations
through 32 bytes, writes through 1,025 bytes, physical stuck-SCL timeouts,
successful reads after recovery, and missing-device NACKs. Earlier testing
exposed an interrupt storm after timeout recovery: SDK `i2c_init` restored an
interrupt mask including TX-empty. The driver now clears that mask before
re-enabling its IRQ.

The [bus recovery test](../tests/hw/rp2350/bus-recovery-rp2350.toit), delivered
through a production OTA envelope, also passed 12 task-deadline cancellations
per controller while the ESP32 physically held SCL low. Each 5 ms task
deadline beat the configured 100 ms native timeout; every cancellation was
followed by GC and a successful read using the same device. The test repeated
the complete 100 kHz baseline above, then ran the SPI ownership, cancellation,
and reuse contract after the peer released its pins. See the
[hardware log](../tests/hw/rp2350/results/2026-09-19-bus-recovery.log) and
[OTA upload log](../tests/hw/rp2350/results/2026-09-19-bus-recovery-upload.log).

Sustained 400 kHz writes remain unresolved. I2C0 passed through 257 bytes but
failed a 1,025-byte write; I2C1 passed through 65 bytes but failed at 257 bytes.
In the latter case the ESP32 reported 112 received bytes, with a mismatch at
byte 80 and no software-buffer drop.
Short reads and combined transactions passed at 400 kHz on both controllers.
The 1 MHz controller capability remains unverified on this rig.

The [I2C investigation](rp2350-i2c-investigation.md) verified the installed
ESP-IDF revision and proved a stale FIFO-count bug with a hardware A/B test.
A reviewable patch removes the extra 32-byte corrupt suffix. A subsequent
instrumented Jaguar run correlated six partial transfers with a full 32-byte
FIFO, co-latched watermark/completion interrupts, and interrupt-service gaps
of approximately 0.99–1.31 ms. The raw overflow flag stayed clear. The cause of
those long gaps and a reliable way to detect the resulting truncation remain
under investigation; the patch alone does not fix early termination.

`i2c.Bus.test` reports `UNIMPLEMENTED`: the RP2350 DesignWare block attaches
START and STOP to data commands and cannot issue the API's address-only probe
without reading or writing a byte on the target. The exercised sources are the
[I2C resource](../src/resources/i2c_rp2350.cc) and
[event-source header](../src/event_sources/i2c_rp2350.h); the tests are
[`i2c-contract-rp2350.toit`](../tests/hw/rp2350/i2c-contract-rp2350.toit),
[`event-stress-rp2350.toit`](../tests/hw/rp2350/event-stress-rp2350.toit),
[`i2c-controller-rp2350.toit`](../tests/hw/rp2350/i2c-controller-rp2350.toit),
and [`i2c-target-esp32.toit`](../tests/hw/rp2350/i2c-target-esp32.toit).

RP2350 `i2c.Target` and `i2c.RegisterTarget` use the same two hardware blocks
and shared event task. They reserve numeric SDA/SCL pins and the corresponding
controller. The target stretches SCL while a dynamic response or register
update is pending. Queued responses retain their unused tail after a short
read; dynamic handler responses discard that tail at the transaction boundary.
Receive-buffer overflow discards the complete write transaction. Register
writes are committed before releasing a repeated-start read.

The target fixtures are [`i2c-target-rp2350.toit`](../tests/hw/rp2350/i2c-target-rp2350.toit),
[`i2c-target-controller-esp32.toit`](../tests/hw/rp2350/i2c-target-controller-esp32.toit),
and [`i2c-target-teardown-rp2350.toit`](../tests/hw/rp2350/i2c-target-teardown-rp2350.toit).
The [version 56 main run](../tests/hw/rp2350/results/2026-09-19-i2c-target-v56.log)
passed both hardware controllers at 100 kHz, including a 257-byte response
streamed through a 64-byte send ring, short-read continuation, dynamic/default
responses, receive overflow and resource reuse. Ten-bit write/read,
general-call reception, register wrap, repeated-start reads, and whole-write
register overflow also passed. The test exposed a general-call boundary bug:
the peripheral acknowledged the write but filtered its STOP interrupt. Broadcast
targets now disable `STOP_DET_IFADDRESSED` so the complete transaction is
delivered.

The [teardown run](../tests/hw/rp2350/results/2026-09-19-i2c-target-teardown-v56.log)
also passed: a child exited from its dynamic read handler while SCL was
stretched, and its parent recreated I2C0 and completed another read in the
same VM. Shared RAM markers make entry into the armed target and handler
mandatory for the verdict. The fixture gives its handler one second for
the diagnostic storage/print RPCs before exit; its earlier 50 ms candidate
hit a task deadline and does not establish a native driver failure.

## Toit VM, GC, GPIO, and ADC results (2026-09-19)

### Platform identity and software reset

The public [`rp2350`](../lib/rp2350/rp2350.toit) library provides `unique-id`
(a fresh eight-byte chip OTP identifier) and `reset`. The standard
`device.hardware-id` and `device.name` APIs now work on RP2350 using that
identifier, while preserving the existing MAC-based identity on ESP32.
The WeAct test board reports chip ID `DC67867C6256ED2B`, matching its USB
serial, and device UUID `4ae56443-c15f-508c-a1fc-ef6fe317a775`.

The [platform test](../tests/hw/rp2350/platform-rp2350.toit) checked identifier
format, independent returned arrays, UUID derivation, and persistence across
a software reset. It reset with a blocked UART reader, an active 3 kHz SPI
transaction, and a GPIO resource still open. The native VM reported reset
reason 2, completed teardown, and booted the same confirmed partition; see
the [confirmed reset log](../tests/hw/rp2350/results/2026-09-19-platform-v43.log).
Here reason 2 is the VM scheduler's reset exit code, not a public hardware
reset-reason API.

The same public reset call in an unconfirmed trial returned to the previous
confirmed partition, again after clean teardown; see the
[rollback log](../tests/hw/rp2350/results/2026-09-19-platform-reset-rollback.log).
To reproduce, install the platform test as a boot container in an envelope
with `expected-id` set to the USB serial and a fresh `reset-token` config
value. Set `reject-trial` to true for the rollback case. Check the USB
disconnects, native reset exit and teardown messages, selected partition,
and final `TOIT-OTA INFO` response as well as the test's PASS line.

A general hardware reset-reason API is not yet implemented. Separate queries
report deep-sleep wakeup and application watchdog expiration.

### Timed deep sleep

`rp2350.deep-sleep` tears down the VM and asks the Pico SDK's power manager
to power down the switched core, XIP cache, and unused SRAM bank. The SRAM
bank containing 4 KiB of RAM bucket storage and clock state remains powered.
This preserves `storage.Bucket.open --ram`, `Time.monotonic-us`, and the
software wall clock across sleep. Ordinary resets and OTA activation clear
that retained state. No RAM contents or code addresses are restored across
firmware changes.

The always-on timer uses the calibrated low-power oscillator. Durations below
one second are raised to one second; startup and teardown add time. GPIO
resources are released and the application watchdog is stopped before power
down. Wakeup runs the normal ROM boot path. `rp2350.woke-from-deep-sleep`
reads the hardware's last-reset latch. External GPIO wakeup is not exposed yet.

An unvalidated trial cannot enter deep sleep: the public call throws
`INVALID_STATE`, preserving the ROM watchdog. Applications validate after
their startup checks before sleeping. `rp2350.reset` remains available to
reject a trial.

The [deep-sleep test](../tests/hw/rp2350/deep-sleep-rp2350.toit) uses a fresh
`sleep-token` configuration and runs minimum-duration, two-second, and
five-second sleeps with UART and SPI work pending. It checks retained RAM,
flash, monotonic and wall clocks, then software and watchdog resets.
It arms a one-second application watchdog before each sleep to check that it
does not interrupt the longer power-down interval. Set `reject-trial` to
exercise rejection before validation. Set `sleep-cycles` to extend the run.

Physical validation passed 20 consecutive timer wakes, followed by software
and watchdog resets. Both ordinary resets cleared retained RAM and clock
state and reported that they were not sleep wakeups. See
[`2026-09-19-deep-sleep-stress.log`](../tests/hw/rp2350/results/2026-09-19-deep-sleep-stress.log).
Trial rejection and rollback also passed in
[`2026-09-19-deep-sleep-trial.log`](../tests/hw/rp2350/results/2026-09-19-deep-sleep-trial.log).

USB shutdown must finish before disabling interrupts and clearing pending
context switches: its timed wait can otherwise leave PendSV pending and
prevent power-down. The SDK fix handles a separate reset-cause issue: POWMAN's
previous sleep-wakeup latch survives a PSM watchdog reset. Retention and wake
classification therefore also check the raw watchdog reset reason, including
ROM software resets and OTA activation.

### Application watchdog

[`rp2350.watchdog`](../lib/rp2350/watchdog.toit) exposes a hardware watchdog
with a 1–16 second timeout, feeding, stopping, and a cached boot-cause query.
It needs no thread or event-task stack. The watchdog is global to the device
and remains armed when its container exits. Normal Toit sleeps do not pause
it, and hardware expiration can recover even with interrupts disabled.

The boot ROM owns the same timer during an OTA trial. Applications must
complete their startup checks and call `system.firmware.validate` before
arming the application watchdog. Starting during a trial throws
`INVALID_STATE`; feed and stop calls before arming are no-ops that preserve
the ROM timeout. OTA activation prevents further task execution once ROM
repurposes the timer for reboot.

Physical verification:

- [ROM trial preservation](../tests/hw/rp2350/results/2026-09-19-watchdog-rom-trial.log):
  repeated application feed/stop calls did not prevent timeout and rollback.
- [Application watchdog](../tests/hw/rp2350/results/2026-09-19-watchdog-application.log):
  argument bounds, rearming, feeding past the timeout, stopping past the
  timeout, expiration after idempotent validation, and reset-cause reporting
  all passed. A subsequent software reset correctly reported a different cause.
- [Native hang](../tests/hw/rp2350/results/2026-09-19-watchdog-native-hang.log):
  an explicitly enabled test injector disabled interrupts and spun without
  calling panic or ROM reboot. The one-second watchdog recovered to a
  confirmed, responsive VM in 3.31 seconds including boot and USB startup.
- [OTA with an active watchdog](../tests/hw/rp2350/results/2026-09-19-watchdog-active-ota.log):
  a four-second watchdog remained fed during a 20.69-second firmware update.
  The new image booted and validated successfully on partition 0.

An initial critical test fixture failed because an inner block shadowed the
outer loop's implicit argument. Its separate `watchdog-fixture-error` logs
are not passing watchdog evidence. The corrected fixture uses an explicit
argument and runs as a noncritical container. The
[recovery log](../tests/hw/rp2350/results/2026-09-19-watchdog-fixture-recovery.log)
records restoration through the wired ESP32 BOOT/RUN helper and the confirmed
recovery UF2, including preserved storage.

The port now runs the 32-bit Toit VM under single-core FreeRTOS. The original
bring-up programs installed service discovery and exited after their tests.
The default build now keeps a USB firmware-update console running after the
test program finishes; see [firmware updates](rp2350-ota.md). Set
`TOIT_RP2350_OTA=OFF` to reproduce the older VM teardown tests. The envelope
build now boots platform services and independently running containers;
storage, container persistence across OTA, and bundled assets/configuration
have passed on the board. Release packaging and complete startup health
policy remain work in progress; see [firmware updates](rp2350-ota.md).

The VM test completed 1,347 garbage collections while retaining and checking
live objects, exercised integer/float arithmetic and timers, then passed GPIO
ownership checks and 100 interrupt transitions plus a quiet-input timeout.
The VM exited normally and completed teardown. See
[`2026-09-19-vm-gpio.log`](../tests/hw/rp2350/results/2026-09-19-vm-gpio.log).

After correcting the GP42/GP40 wiring mistake, both ADC paths passed a
seven-step DAC staircase, alternating channels and checking lifetime/pin
ownership. GP40 measured 0.096–2.853 V and GP41 measured 0.083–2.789 V over
nominal 0–3 V DAC settings. Intermediate points were within 14 mV of a
line fitted through each channel's endpoints. This checks tracking and
channel selection, not absolute DAC/ADC calibration. See
[`2026-09-19-adc.log`](../tests/hw/rp2350/results/2026-09-19-adc.log).
The UART transcript is
[`2026-09-19-uart.log`](../tests/hw/rp2350/results/2026-09-19-uart.log).

## Peripheral event dispatch

GPIO, UART, I2C, SPI, and USB stdin share one 8 KiB event task. Drivers retain their own VM
resource mutexes and bounded pending state; an interrupt only updates that
state and signals a shared binary semaphore. No peripheral owns a separate
thread or event queue. Compared with the initial three-thread implementation,
this saves 16 KiB of stacks plus two task control blocks and queue storage.

The dispatcher sleeps indefinitely with no active work. UART physical
transmit completion, SPI completion, and active I2C deadlines temporarily request a 1 ms poll;
the existing VM timer service has its own timer thread, as on ESP32. Source
registration and destruction are synchronized against dispatch, and interrupts
are disabled before their peripheral state is released. New peripheral drivers
must join this dispatcher rather than create another task.

The shared-thread implementation passed physical regression tests on
2026-09-19:

- [Concurrent stress](../tests/hw/rp2350/results/2026-09-19-event-stress.log):
  two GPIO waiters across 288 transitions, 1,024 UART write/flush cycles,
  512 missing-device I2C transfers across both controllers, 800 timer waits,
  repeated close/reopen cycles, and clean VM teardown.
- [GPIO and GC](../tests/hw/rp2350/results/2026-09-19-shared-event-gpio-gc.log):
  1,341 collections, GPIO resource checks, 100 interrupt transitions, a
  quiet-input timeout, and clean teardown.
- [UART](../tests/hw/rp2350/results/2026-09-19-shared-event-uart.log):
  echo through 4,096-byte payloads, baud changes through 921,600 requested
  baud, overflow/recovery, and clean teardown.

The standalone stress image is built by selecting
`tests/hw/rp2350/event-stress-rp2350.toit` as `RP2350_PROGRAM`. It requires
GP34 unconnected and the ESP32 helper stopped with its I2C pins released.

The [concurrent target fixture](../tests/hw/rp2350/target-event-stress-rp2350.toit)
also passed four phases on native v59. Each phase ran eight 97-byte I2C1
register write/read operations alongside 64-byte SPI0 target transfers,
GP32 level waits, UART coordination, and sixteen forced GCs per round.
I2C ran at 100/400 kHz; SPI ran in modes 1/3 at 100 kHz without DMA and
1 MHz with DMA. Every phase closed and recreated both targets. All 32 rounds
passed with zero dropped SPI receives or I2C register writes. See the
[RP log](../tests/hw/rp2350/results/2026-09-20-target-event-stress-v59-rp.log)
and [ESP log](../tests/hw/rp2350/results/2026-09-20-target-event-stress-v59-esp.log).

This test exposed an I2C RegisterTarget refill bug: when interrupt latency
allowed the FIFO to empty during a read, a repeated hardware read request
reset the register cursor and replayed the response prefix. The driver now
preserves the cursor until the read ends. The same concurrent test then
passed, followed by the complete standalone target/register matrix; see its
[v59 regression log](../tests/hw/rp2350/results/2026-09-20-i2c-target-v59-rp.log).

## PWM result (2026-09-19)

The PWM driver passed physical tests on GP6/GP7 using ESP32 GPIO18/GPIO23 as
observers. Quarter, half, and three-quarter duty measured 249, 494, and 747
permille; 1 kHz and 2 kHz requests measured 1004 Hz and 2009 Hz. Exact low/high
output, shared-slice frequency changes, independent channel close, group
cleanup, numeric-pin validation, and ownership conflicts also passed. See
[`2026-09-19-pwm.log`](../tests/hw/rp2350/results/2026-09-19-pwm.log).

PWM uses hardware slices and does not allocate an event thread. The live test
also exposed a C++ cleanup closure that allocated through throwing `new` inside
a primitive. PWM, UART, ADC, and I2C allocation paths now use explicit cleanup;
compiled-object checks confirm only nothrow allocation for these drivers.
Each slice belongs to one `Pwm` instance at a time; its channels share timing.
The achievable frequency depends on the requested period and the hardware
clock divider, so the generic API's full frequency range is not available.

## SPI result (2026-09-19)

The controller driver uses FIFO interrupts and the shared event dispatcher.
Its [physical contract test](../tests/hw/rp2350/results/2026-09-19-spi-contract-reset.log)
passed numeric-pin and ownership checks, both controllers, timeout/abort
recovery, and resource cleanup. With the ESP32 on alpha.199, the peer uses the
hardware `spi.Target` API. The
[paired hardware test](../tests/hw/rp2350/results/2026-09-19-spi-alpha199-hardware-v34.log)
passed modes 0–3, 3 kHz/100 kHz/1 MHz clocks, full-duplex transfers through 60
bytes, command/address prefixes, and chip select retained across split
transfers. The application exited cleanly and the OTA console remained usable.
Nonzero CS setup/hold cycle counts are unsupported (`UNIMPLEMENTED`), and
the combined command/address prefix must contain a whole number of bytes.

The RP2350 SPI target implementation uses the same two PL022 blocks, so target
pins reserve the corresponding SPI controller and cannot coexist with a
controller bus on that block. Pin names are target-relative: on SPI0, GP4 is
MOSI input, GP7 is MISO output, GP6 is clock, and GP5 is active-low CS. SPI1
uses GP8, GP11, GP10, and GP9 in the same order. Only numeric `GPx = x`
identifiers are accepted.

PL022 target mode has a hardware frame-select limitation. Modes 1 and 3 keep
CS active across a multi-byte transaction and are supported. Modes 0 and 2
require CS to pulse between individual PL022 frames and are rejected with
`INVALID_ARGUMENT`; use another SPI mode when the controller allows it. The
target counts complete bytes. If CS rises partway through a byte, those trailing
bits are discarded. `Target` completes when its configured byte limit is
reached even if CS remains low. `BufferTarget` remains CS-delimited, caps an
overlong transaction at its configured buffer size, and starts the next
transaction from offset zero after CS rises.

DMA targets claim one RX and one TX DMA channel even for a one-directional API
configuration: RX counts controller clocks and TX supplies fill bytes. The
non-DMA path uses the PL022 FIFO interrupts and retains the public 64-byte
limit. Both paths deliver Toit state through the existing shared event task;
the raw 64-bit GPIO CS handler coexists with the ordinary GPIO bank callback.

The target contract and paired rig programs are
[`spi-target-contract-rp2350.toit`](../tests/hw/rp2350/spi-target-contract-rp2350.toit),
[`spi-target-rp2350.toit`](../tests/hw/rp2350/spi-target-rp2350.toit), and
[`spi-controller-esp32.toit`](../tests/hw/rp2350/spi-controller-esp32.toit).
They cover both blocks, high-bank pin ownership, DMA and FIFO transfers, LSB
ordering, early CS byte counts, completion with CS held low, cancellation and
reuse, and BufferTarget overlength recovery. Physical validation passed on
both SPI blocks in modes 1 and 3, with and without DMA, at 400 kHz. SPI0
also passed independent transmit/receive bit order, consecutive 1/3/7/9-byte
transactions with different responses, early CS after 1/3/7 bytes of an
8-byte DMA buffer, completion with CS held low at 100 kHz, and cancellation
followed by reuse. Both BufferTarget paths passed short, overlong, and
subsequent transactions with zero dropped receives. See the
[paired v58 log](../tests/hw/rp2350/results/2026-09-20-spi-target-paired-v58-final.log)
and [artifact checksums](../tests/hw/rp2350/results/2026-09-20-spi-target-v58.sha256).

The early-CS test found that DMA's transfer-count register was not a reliable
progress counter after abort. The driver now waits for writes to retire, uses
the destination-address delta, checks its bounds, and drains residual FIFO
bytes. Arming also clears stale CS edges. The peer finishes configuring CS
before acknowledging a case, and an explicit UART startup handshake discards
reset noise. The buffered fixture reserves room for its three back-to-back
transactions and bounds its receive waits.

The physical process-exit test passed three cycles in one VM. Each child
exited with DMA targets armed on both SPI blocks; the parent then reacquired
the controllers and pins and reran the complete ownership contract. This
exercises native teardown without a reboot clearing leaked resources. See
the [v58 teardown log](../tests/hw/rp2350/results/2026-09-20-spi-target-teardown-v58.log).

## Final container persistence check (2026-09-20)

The fresh version 59 regression installed a flash container through the public
API, ran it as a separate process, carried it across OTA, observed its boot
startup, and uninstalled it. A subsequent OTA reboot into the privileged
registry diagnostic found zero program allocations, retained all seven storage
regions, and passed the normal persistent bucket/region and GC checks. See the
[install](../tests/hw/rp2350/results/2026-09-20-container-install-fresh-v59.log),
[uninstall](../tests/hw/rp2350/results/2026-09-20-container-uninstall-fresh-v59.log),
and [post-reboot inventory](../tests/hw/rp2350/results/2026-09-20-container-durable-inventory-v59.log)
logs, with [artifact hashes](../tests/hw/rp2350/results/2026-09-20-container-durable-v59.sha256).

Earlier bring-up left an older child image that still started after cleanup.
The public container list is keyed by image UUID, while the physical registry
is keyed by offset; repeated commits can therefore hide earlier copies of the
same image. The earlier logs did not record physical offsets, so they cannot
establish the exact cause. The remaining old allocation was identified at
offset zero, uninstalled, and independently shown absent both immediately and
after reboot. No native erase change was needed. The fresh regression above
then confirmed durable removal through the public API. It does not establish
a deduplication contract for repeated identical commits in the shared
container manager.

The read-only `registry-inventory-boot.toit` fixture is a privileged system
snapshot, not an ordinary application container. Initialize platform services
before printing, then scan independently before starting boot containers. An
earlier diagnostic printed too early, blocked on service discovery, and was
rejected by the trial watchdog; the corrected diagnostic and the normal
healthy firmware remained reachable through OTA.

The rig was finally restored to immutable healthy v59 and confirmed on
partition 1 (`TOIT-OTA INFO 1 1 0 4194304`), with no child startup and passing
storage/GC/identity checks. See the
[final boot log](../tests/hw/rp2350/results/2026-09-20-final-healthy-v59.log).
The ESP32 was restored byte-for-byte to its original official alpha.199 image;
its restoration proof is in the [I2C investigation](rp2350-i2c-investigation.md).
Both serial ports were released.
