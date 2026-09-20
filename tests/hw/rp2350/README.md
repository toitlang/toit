# RP2350 hardware tests

These tests run on the WeAct RP2350B board and its wired ESP32 DevKitC V4
helper. The [rig guide](../../../docs/rp2350-rig-guide.md) records the complete
wiring, persistent USB identities, measured wire tests, and recovery procedure.
Pin arguments are numeric GP identifiers; GP40 is `40`, independently of its
header position.

Paired tests use `<name>-rp2350.toit` and `<name>-esp32.toit`. Only one test
owns the rig at a time: UART carries coordination messages, and several GPIOs
serve different roles across GPIO, I2C, and SPI tests. Stop the preceding ESP32
helper before changing roles. Keep BOOT and RUN released unless intentionally
resetting or entering ROM download mode.

## Running a bring-up program through OTA

Build the matching host SDK and a native test image from the repository root:

```sh
make rp2350 \
  RP2350_PROGRAM="$PWD/tests/hw/rp2350/uart-rp2350.toit" \
  RP2350_VERSION=55 \
  RP2350_CMAKE_FLAGS=-DTOIT_RP2350_OTA=ON
make rp2350-ota-upload
```

`RP2350_VERSION` is the ROM image version; choose a value for the test sequence.
Equal-version and downgrade uploads are supported too. The bring-up boot
program confirms its image after starting the VM and services and collecting
garbage. This lets long hardware tests run beyond the ROM trial deadline.
Production envelopes instead require an application to call
`firmware.validate` after its own startup checks.

Stage the RP image before starting the matching ESP32 helper. Uploading can
take longer than the helper's initial coordination timeout:

```sh
build/rp2350-ota-upload/ota-upload \
  --port /dev/serial/by-id/usb-Raspberry_Pi_Pico_DC67867C6256ED2B-if00 \
  --no-reboot build/rp2350-vm/toit-rp2350.bin
jag run tests/hw/rp2350/uart-esp32.toit --device opposite-singer
```

Capture ESP32 serial output before deploying its helper; `jag run` reports
deployment success but does not show the running program's output. Close any
other RP serial monitor before uploading. After staging and deployment, open a
115200-baud serial monitor that reconnects after USB removal. Send the line
`TOIT-OTA REBOOT` to activate the staged image and capture the test's startup
and final verdict. That command activates a staged OTA image; it is not a
general reset command. Each fixture's source describes its startup delay and
coordination protocol. A timeout, missing verdict, or shortened response is
a failed or incomplete run, never a substitute for the expected assertions.

The [OTA guide](../../../docs/rp2350-ota.md) covers trial rejection, rollback,
image validation, normal envelope creation, and restoring a healthy image.

`registry-inventory-boot.toit` is a diagnostic system program, not an ordinary
hardware-test application. Compile it as the envelope's privileged system
snapshot and keep the healthy critical validator as a separate boot container.
It constructs `Platform` first so the service needed by `print` is available,
then scans and prints each physical flash-registry allocation through an
independent registry before starting any run-boot container. To check that an
uninstall is durable, capture one inventory, run the cleanup application,
reboot, and capture a second inventory; absence from
`system.containers.images` before that reboot only proves that the current
manager no longer exposes the image.

## Coverage and evidence

| Area | Fixtures | What they check |
| --- | --- | --- |
| GPIO | `vm-gpio-smoke`, `gpio-resource`, `gpio-interrupt` | Ownership, numeric pins, pulls, edge waits and GC |
| Analog/PWM | `adc`, `pwm` pairs | Both DAC-to-ADC wires and PWM signal measurement |
| UART | `uart` pair | Exact data, baud changes, overflow, recovery and release |
| I2C controller | `i2c-controller`, `i2c-contract`, `i2c-leak`, ESP `i2c-target` | Both controllers, reads/writes, repeated starts, timeout/cancel and ownership |
| I2C target | `i2c-target`, `i2c-target-teardown`, ESP `i2c-target-controller` | Both controllers at 100 kHz, streamed and dynamic responses, short reads, registers, 10-bit/general-call addressing, overflow and same-VM teardown/reuse; physical runs passed |
| SPI controller | `spi-controller`, `spi-contract`, ESP `spi-target` | Four modes, full duplex, prefixes, CS handling and cleanup |
| SPI target | `spi-target`, `spi-target-contract`, `spi-target-teardown`, ESP `spi-controller` | Both hardware blocks in modes 1/3, DMA/FIFO transfers, bit order, short/overlong/held-CS transactions, cancellation, ownership and three process-exit/reuse cycles; physical runs passed |
| Shared event task | `event-stress`, `bus-recovery` | Concurrent peripheral work, cancellation and subsequent reuse |
| Concurrent targets | `target-event-stress` pair | I2C registers at 100/400 kHz, hardware SPI targets in modes 1/3 with and without DMA, GPIO waits, UART and 512 forced GCs; all four physical phases passed |
| VM/storage | `vm-smoke`, `memory-pressure`, `storage-*`, `container-*`, `envelope` | GC, flash/RAM buckets, raw regions, assets/config and independent containers |
| Reset/watchdog | `platform`, `watchdog-*`, `native-failure-test.py` | Identity, clean resets, native failures, watchdog recovery and trial rollback |
| Deep sleep | `deep-sleep` | Repeated timer wakes, retained RAM/clocks, peripheral teardown and reset-cause discrimination |

The table names file stems; RP-only fixtures end in `-rp2350.toit`. Some
storage, watchdog and sleep fixtures need configuration or multiple boots;
read their source and the linked guides before running them.

RP2350 SPI targets support modes 1 and 3. Modes 0 and 2 throw
`INVALID_ARGUMENT`, because the hardware requires CS pulses between frames in
those modes. SPI controllers support all four modes.

`results/` contains both passing runs and diagnostic failures. The rig and OTA
guides identify which logs prove each result and explain earlier failed
candidates. In particular, the classic ESP32 target's intermittent 400 kHz
NACK remains under investigation; the passing standalone native target is
not evidence that the Jaguar target has been fixed. See the
[I2C investigation](../../../docs/rp2350-i2c-investigation.md).

Host-only parser, envelope and retained-memory layout checks live in
[`tools/rp2350/tests`](../../../tools/rp2350/tests/README.md).
