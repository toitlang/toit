# RP2350 hardware tests

These tests use a WeAct RP2350B Core Board and a classic ESP32 DevKitC V4 with
a WROOM module. GPIO16/17 must be available; a WROVER module using them for
PSRAM is not compatible with this mapping. All numbers are GPIO identifiers,
not physical header positions.

## Wiring

Power both boards through USB and join their grounds. Do not connect their
regulated 3.3 V outputs. Both boards must be powered when driving test signals.

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
| GP32 | 22 | 220 ohm | GPIO, interrupts, PWM |
| GP33 | 17 | 1 Mohm | Weak high/low stimulus for internal-pull tests |
| GP33 (same node) | 35 | 220 ohm | Independent observation of the pull-test node |
| GP40 / ADC0 | 25 / DAC | 4 kohm | Analog stimulus |
| GP41 / ADC1 | 26 / DAC | 10 kohm | Second analog stimulus |
| RUN | 21 | 220 ohm | Reset, open-drain output |
| BOOT button's non-ground contact | 16 | 220 ohm | Bootloader entry, open-drain output |

SPI names above assume RP2350 controller mode; target tests reverse the data
roles. ESP34/35 are input-only without internal pulls. The mapping avoids
ESP32 strapping pins and leaves UART0 free for the USB console. RP GP0 is
reserved for the board's optional secondary flash/PSRAM chip-select. GP40/41
are dedicated to ADC tests; the series resistors are not voltage dividers.
Use slow settled DAC levels, not these wires as precision voltage references.

Add removable 4.7 kohm pull-ups from GP4, GP5, GP10 and GP11 to the WeAct 3.3 V
rail, on the RP side of the series resistors. Keep them for I2C tests and
remove them for internal-pull tests. GP33 has only the 1 Mohm stimulus and
ESP35 observation connections: driving ESP17 low should leave an enabled RP
pull-up high, and driving ESP17 high should leave an enabled RP pull-down low.
Record the silicon revision when diagnosing weak-pull failures: the RP2350 A2
E9 input-leakage erratum can affect them; the B in RP2350B denotes the package.

Check each wire before running paired tests. The native
`toit-rp2350-rig-test` target and `rig-test-esp32.toit` exercise digital wires,
pulls and both ADC paths. Keep [wiring.toit](wiring.toit) and the helper's
[control mapping](../../../tools/rp2350/wiring.toit) consistent with the table
when changing connections.

BOOT and RUN outputs must start released and use open-drain operation: drive
low or release, never drive high. BOOT connects on the button side of the
WeAct's onboard resistor to flash chip-select. RST duplicates RUN; KEY is a
separate button on GP23 and needs no additional connection. The user LED is
GP25.

To enter ROM boot mode, hold BOOT low, pulse RUN low, release RUN, then release
BOOT after the ROM has sampled it. The helper
`tools/rp2350/bootloader-esp32.toit` performs this sequence. Confirm USB device
`2e8a:000f`; a disconnect/reconnect alone also occurs on ordinary resets.

Use `/dev/serial/by-id/` paths on Linux to avoid tty renumbering. Identify the
ESP32 by its USB bridge serial and the RP2350 by its board serial. Application
USB names can change with firmware; ROM mode has no application serial port.
Use picotool's board serial selector in ROM mode when multiple boards are
connected.

## Running a test

[Build the port](../../../docs/rp2350.md) and provision a healthy envelope
before starting the test sequence. Only one test owns the rig at a time:
UART carries coordination messages and GPIOs serve different peripherals
across tests. Stop the previous ESP32 helper before switching roles. Keep
BOOT and RUN released except during deliberate resets.

Build a test image and the native uploader from the repository root:

```sh
make rp2350 \
  RP2350_PROGRAM="$PWD/tests/hw/rp2350/uart-rp2350.toit" \
  RP2350_VERSION=2
make rp2350-ota-upload
```

The test wrapper confirms after VM/service startup and a GC, then runs the
application in a separate noncritical container. Production envelopes instead
require an application health check followed by `system.firmware.validate`.
Use `RP2350_CMAKE_FLAGS=-DTOIT_RP2350_AUTO_VALIDATE=OFF` for a rollback test.

Stage before starting the paired ESP32 helper; uploading can exceed the
helper's initial coordination timeout. Replace the serial and Jaguar device
placeholders with the devices identified above:

```sh
build/rp2350-ota-upload/ota-upload \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  --no-reboot build/rp2350-vm/toit-rp2350.bin
jag run tests/hw/rp2350/uart-esp32.toit --device ESP32_DEVICE
```

Capture ESP32 output before deployment: a successful `jag run` only confirms
deployment. Close other RP serial monitors during upload. After staging and
helper deployment, open a 115200-baud serial monitor that reconnects after USB
removal, then send `TOIT-OTA REBOOT` to activate the staged image. This command
activates an update; it is not a general reset command. Require each fixture's
final assertions or PASS verdict; timeouts and missing output are incomplete
runs. Restore a healthy validating envelope after fault or rollback tests.

## Test selection

For TLS, build `tls-session-rp2350.toit` and run `tls-session-host.toit` on the
host with a TCP listen port as its argument. The ESP32 runs
`tls-session-esp32.toit` as a UART-to-TCP relay; the stock ESP32 firmware has
no TLS server. Jaguar cannot pass program arguments, so create an ignored
`build/rp2350-tls-peer.toit` wrapper with the host address and chosen port:

```toit
import ..tests.hw.rp2350.tls-session-esp32 as peer
main: peer.main ["HOST_ADDRESS", "19443"]
```

The relay resets the RP2350 after connecting. Start it after activating the
test image. The host requires a final acknowledgement sent only after the
RP2350 verifies session export and every encrypted echo.

| Area | File stems | Coverage |
| --- | --- | --- |
| GPIO | `vm-gpio-smoke`, `gpio-resource`, `gpio-interrupt` | Ownership, numeric pins, pulls, edge waits and GC |
| Analog/PWM | `adc`, `pwm` pairs | Both DAC-to-ADC wires, last-close/reopen, and PWM measurement |
| UART | `uart` pair | Exact data, RS485 direction, baud changes, overflow, recovery and release |
| I2C controller | `i2c-controller`, `i2c-contract`, `i2c-leak`, ESP `i2c-target` | Both controllers, repeated starts, timeout/cancellation and ownership |
| I2C target | `i2c-target`, `i2c-target-teardown`, ESP `i2c-target-controller` | Streaming, dynamic responses, short reads, registers, addressing, overflow and reuse |
| SPI controller | `spi-controller`, `spi-contract`, ESP `spi-target` | Four modes, duplex, prefixes, chip-select and cleanup |
| SPI target | `spi-target`, `spi-target-contract`, `spi-target-teardown`, ESP `spi-controller` | Both blocks in modes 1/3, DMA/FIFO, bit order, short/overlong transfers, cancellation and reuse |
| Shared event task | `event-stress`, `bus-recovery`, `target-event-stress` pair | Concurrent buses, GPIO waits, UART, cancellation and forced GC |
| VM/storage | `vm-smoke`, `memory-pressure`, `storage-*`, `container-*`, `envelope` | GC, persistent storage, assets/config and containers |
| Reset/watchdog/sleep | `platform`, `watchdog-*`, `deep-sleep` | Resets, watchdog recovery, trial rollback and timer wakes |

RP-only fixtures end in `-rp2350.toit`; peers end in `-esp32.toit`. Some need
configuration or multiple boots: read the fixture before running it. SPI
targets reject modes 0/2; controllers support all modes. I2C scanning is TODO.
The classic ESP32 Jaguar I2C target can intermittently NACK at 400 kHz; a
passing native target does not establish that the Jaguar target is fixed.

`registry-inventory-boot.toit` is a diagnostic system snapshot. Compile it as
the envelope's privileged system program, with a healthy critical validator
as a separate boot container. It inventories physical registry allocations
before boot applications start. To test durable uninstall, compare inventories
before cleanup and after a reboot; removal from the running container
manager's list alone is insufficient.

[Host-only tests](../../../tools/rp2350/tests/README.md) cover parser boundaries,
envelope extraction, hashes and retained-memory layout. The
[update design](../../../docs/rp2350-ota.md) describes staging and rollback
invariants to check during hardware fault tests.

Host-driven hardware checks use the matching host SDK and the bootstrapped
package cache. For example, reject malformed updates while keeping a healthy
confirmed image running:

```sh
TOIT_PACKAGE_CACHE_PATHS="$PWD/tools/.packages-bootstrap" \
  build/host/sdk/bin/toit run tests/hw/rp2350/ota-negative-test.toit -- \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_SERIAL-if00 \
  --image build/rp2350-vm/toit-rp2350.bin
```

`native-failure-test.toit` additionally takes `--uploader`, `--fault`, and
`--log`; `--validated` tests restart after confirmation instead of trial
rollback. Build its image with `TOIT_RP2350_TEST_FAULT` set to the matching
fault. `container-failure-test.toit` checks application isolation, and
`container-assets.toit` prepares envelope fixtures. Each runner's source
lists the remaining inputs.
