# EC618 rig guide

Use this guide for building, identifying, flashing, and testing the two EC618
boards. [Open work](ec618-todo.md) and [design notes](ec618-design-notes.md)
are separate. Test protocols live beside the tests in
[`tests/hw/ec618`](../tests/hw/ec618/README.md).

## Boards and port identification

| Board | Role | Console / identity |
| --- | --- | --- |
| EC618 Air780E dev board | Wired peripheral tests | UART0, CH340 adapter |
| EC618 module | Standalone, cellular, recovery tests | UART1, CH340 adapter |
| Classic ESP32 `modest-affair` | UART/GPIO/PWM/ADC helper; I2C0 target | CP2102 serial `10cbfb2cfbfaea11a8485a185fbcde76` |
| Dedicated ESP32-S3 | I2C1/SPI target | USB serial `595B005743`; octal PSRAM |
| ESP32-C6 `quirky-plenty` | Module power and boot control | USB serial `40:4C:CA:41:31:20` |

Rediscover ports after reconnecting a hub. The two CH340 adapters can share one
`/dev/serial/by-id` name; use USB topology (`/dev/serial/by-path`) and confirm
with the mini-jag banner: `control uart=0` identifies the dev board and
`control uart=1` the module. `doctor-ec618.toit` reports the base identity,
slot, and console. A console is normally 115200 baud.

The independent ESP32 regression pairs use `/dev/ttyEsp32Board{1,2}` and
`/dev/ttyEsp32s3Board{1,2}` on the current host. They are separate from the
EC618 helper boards. Host-local instructions and Wi-Fi configuration are in
`/home/flo/work/opentoit-fix-ci/GITIGNORE`; use that rig's CTest preflight and
setup before testing new firmware. Ultrasound tests need an obstacle in range.

## Wiring

[`wiring.toit`](../tests/hw/ec618/wiring.toit) is the executable source of signal
assignments. EC618 digital pin numbers are physical PAD indices, not module
GPIO labels. The rig uses 3.3 V digital IO; analog inputs use voltage dividers.

| EC618 dev-board contact | PAD / function | Classic ESP32 GPIO |
| --- | --- | --- |
| 3 | AIO3 / ADC0 | DAC25 through divider |
| 4 | AIO4 / ADC1 | DAC26 through divider |
| 5, 14 | PAD26 / UART2 TX, SPI clock | 27, 21 (same net) |
| 6, 11 | PAD25 / UART2 RX, SPI MISO | 14, 32 (same net) |
| 9 | PAD42 / GPIO22, wake | 13 |
| 10 | PAD23 / I2C1 SDA, SPI CS | 33 |
| 12 | PAD16 / PWM TIMER0 | 23 |
| 13 | PAD24 / I2C1 SCL, SPI MOSI | 22 |
| 18 | PAD44 / GPIO24, PWM TIMER1 | 19 |
| 22 | PAD14 / I2C0 SDA | 18 |
| 23 | PAD13 / I2C0 SCL | 17 |
| 27 | PAD47 / GPIO27, PWM TIMER4 | 2 |
| 30 | PAD34 / UART1 TX | 4 |
| 31 | PAD33 / UART1 RX, PWM TIMER4 | 16 |

The removed RC522/BME280 wires now reach the dedicated S3:

| Signal | EC618 PAD | S3 GPIO |
| --- | --- | --- |
| SPI CS | 23 | 7 |
| SPI clock | 26 | 6 |
| SPI MOSI | 24 | 5 |
| SPI MISO | 25 | 4 |
| I2C1 SCL | 24 | 13 |
| I2C1 SDA | 23 | 12 |

S3 GPIO7/12 share a net, as do GPIO5/13. Run I2C and SPI target roles
sequentially. SPI also shares the classic helper's UART2 wires, so use UART1
for bus-test control. Reset the S3 into its idle fixture before unrelated
GPIO/UART tests. Keep all wired boards powered to avoid clamping shared nets.

## Build and base compatibility

Install CMake, Ninja, xmake, and ectool. The default `EC618_GCC_PATH` selects
xmake's pinned GNU Arm 10.3-2021.10 installation. Pass an explicit toolchain
root when qualifying another compiler; the base and slot must use the intended
roots consistently. Preserve the deployed base's `base.elf`, `base.bin`, and
manifest so matching slots can be built later.

```sh
make ec618-base                 # Required after any base-side change.
make ec618                      # Builds host tools, slots, envelope, and guards.
# Or build against a saved/released base:
make ec618 EC618_BASE_DIR=/path/to/base-artifacts
```

`make ec618` creates a base only if none exists. Changes under
`toolchains/ec618/project`, the SDK, base toolchain, or base configuration
require an explicit base rebuild. Bump `toolchains/ec618/base-version` for a
shipped base change. Slot OTA requires the exact base version and fingerprint;
a new base requires a full flash. Firmware envelopes carry their matching AP
base, CP image, and relocation metadata.

The built envelope has no resident test agent. `tester setup` and
`firmware-update` add mini-jag and the sleeper automatically. For manually
prepared images, add both before extracting the flash image. The sleeper keeps
the VM alive if the agent exits; silence from an agentless image does not prove
a boot failure.

## Full flash

Use a verified console path below. Ectool discovers the separate boot-ROM USB
interface itself; the tester's `--port` is used to verify the running agent
once flashing finishes. `ECTOOL_PATH` can select a specific ectool executable.
The normal firmware tool flashes the AP and matching CP, preserving the
bootloader.

```sh
build/host/sdk/bin/toit run tests/hw/esp-tester/tester.toit -- setup \
    --chip ec618 --toit-exe build/host/sdk/bin/toit \
    --port /dev/verified-console --envelope build/ec618/firmware.envelope
```

Prepare the image before entering boot mode: the boot-ROM window is short.
For the dev board, the operator enters download mode and runs the flash command
locally. After a power interruption it may also need a two-second PWRKEY press.

For the module, C6 GPIO19 drives USB_BOOT high and GPIO23 controls its 5 V
relay. Host-local `dev/ec618-rig/boot-high.toit` enters download mode;
`boot-run-hold.toit` power-cycles normally and holds power for 60 minutes.
Start the flasher before triggering download mode and maintain power throughout.

The default provisioned image uses UART0. For the module, prepare the agent
image as a binpkg and select UART1 before burning:

```sh
build/host/sdk/bin/toit run --project-root tools tools/ec618/provision.toit -- \
    --image=tester.binpkg --out=module.binpkg --console-uart=1
# Start this before triggering boot mode:
ectool burn --burn_bl n --burn_cp y -f module.binpkg
```

## Run tests and OTA

Launch a paired ESP32 helper first:

```sh
jag run tests/hw/ec618/uart2-esp32.toit --device modest-affair
build/host/sdk/bin/toit run tests/hw/esp-tester/tester.toit -- run \
    --chip ec618 --toit-exe build/host/sdk/bin/toit \
    --port-board1 /dev/verified-console tests/hw/ec618/uart2-ec618.toit
```

`jag run` reports deployment; read the helper's serial console for its verdict.
Keep a single `jag monitor --attach --port <helper-port>` running when Jaguar
needs its serial relay. Stop that monitor before flashing a standalone fixture.
Do not put two readers on one serial port. Opening a helper adapter may toggle
DTR and reset it.

The EC618 tester uses the container's exit code. `--arg=value` supplies a test
argument; an omitted argument arrives as an empty string. UART2 duplex and ring
tests use `uart2-bigdata-esp32.toit` as their peer. Redeploy the required helper
before each paired test and inspect both sides' results.

```sh
build/host/sdk/bin/toit run tests/hw/esp-tester/tester.toit -- firmware-update \
    --toit-exe build/host/sdk/bin/toit --port /dev/verified-console \
    --envelope build/ec618/firmware.envelope
```

OTA installs the inactive slot, boots a trial, runs a smoke test, and validates.
Use `--no-validate` only for a deliberate rollback test. `--console-uart=1`
attaches a new console to the staged trial; do not change the running image's
console independently. The tester restores 115200 baud after a successful run.

For a test larger than the 64 KiB registry, compile an O2 snapshot with asserts,
add it to a temporary envelope as a named `test` container with `--trigger=none`,
OTA that envelope, then use `tester run-embedded`. Restore the normal envelope
afterward. Use the matching SDK and the project's package lock when compiling.

## Regression groups

| Group | Entry points / setup |
| --- | --- |
| Standalone on both EC618s | doctor, clock, base-id, slot-size, float-format, ADC/cellular/firmware-writer lifecycle, basics, GC, storage and multipage storage |
| Cellular on the module | DNS, TCP, HTTPS, UDP/NTP; requires a working SIM and network |
| Dev-board peripherals | GPIO map/input/output/interrupt/open-drain/lifetime, ADC, PWM/AON, UART config/stress/ring/duplex/RS485/gap-free/lifetime |
| I2C1 and SPI | `bus-controller-ec618.toit` with the S3 target and classic UART1 bridge |
| I2C0 | Same controller with `--arg=i2c0`, classic standalone target; keep S3 idle |
| Reset and deep sleep | Watchdog, RTC persistence, wake/reset contract programs; follow their persisted-phase setup and recovery instructions |

Follow the [programmable fixture procedure](../tests/hw/ec618/README.md#programmable-i2cspi-fixture)
for bus setup. It covers I2C at 50/100/400 kHz through 1,025 bytes, and SPI in
all four modes through 32 KiB with prefixes and cancellation/reuse. The classic
I2C0 target supports basic transactions; register targets and response-time
stretching require the S3. Restart the coordinator for every controller run.

## Diagnosing a rig failure

Run `toit run --project-root tools tools/ec618/doctor.toit` on the host and
`doctor-ec618.toit` through the tester. Check identities, power, fixture ownership,
and both peers' output before attributing a timeout to a driver. NTP servers
can return invalid timestamps; preserve the failure and distinguish a server
retry from a firmware fix.

ESP32 pulse counters, RMT capture, and GPIO inputs can independently verify
edges, pulse widths, and bus timing. The classic helper observes I2C0 SCL on
GPIO17 and SDA on GPIO18. Release any competing target before measurement.
If using a socat PTY for a rescue UART lane, set `stty -F <pty> min 1 time 0`;
otherwise a reader can return EOF merely because no byte is immediately ready.
