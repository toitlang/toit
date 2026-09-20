# ESP32-H2 hardware tests

Build the SDK and H2 firmware with `make esp32h2`. The envelope is
`build/esp32h2/firmware.envelope`. Use the serial control transport of
`tests/hw/esp-tester/tester.toit`; H2 has no Wi-Fi.

Set `H2_PORT` and `HELPER_PORT` to the boards' `/dev/serial/by-id/` links so
tty renumbering does not swap the roles. Both boards share ground and use USB
power. The current rig uses an ESP32-H2-DevKitM-1 and ESP32-DevKitC-V4.

| H2 GPIO | ESP32 GPIO | Constraint |
| --- | --- | --- |
| 0 | 12 | Release H2 without pulls before resetting the helper: GPIO12 is a flash-voltage strap. |
| 1 | 14 | Bidirectional. |
| 2 | 27 | Bidirectional. |
| 3 | 26 | Bidirectional; helper DAC can drive H2 ADC. |
| 4 | 32 | Bidirectional; also used for pull tests. |
| 5 | 35 | Helper input only, without internal pulls. |
| 10 | 13 | Bidirectional; H2 external deep-sleep wakeup. |
| 13 | 25 | Reserved: leave helper GPIO25 input without pulls. |

Helper GPIO33 connects through **1 MΩ** to helper GPIO32. H2 GPIO14 is
disconnected from the helper. Leave H2 GPIO13/14 alone because the board may
use them for its low-frequency crystal.

## Wiring check

`wiring-fixture` is an ESP-IDF C project that builds for either `esp32h2` or
`esp32`. Build it in separate directories with the corresponding `IDF_TARGET`
and `SDKCONFIG` paths, then flash each board. The fixture releases its pins
after three seconds without a command.

This is a bootstrap check for use before the new port is trusted. Its C fixture
runs on both boards; the explicit chip branches select their pin whitelists.
The normal Toit suites below make the ESP32 the tester.

Run the Toit host check from the repository root:

```sh
build/host/sdk/bin/toit run tests/hw/esp32h2/check-wiring.toit -- \
  --h2-port "$H2_PORT" --helper-port "$HELPER_PORT" \
  --output wiring-results.json
```

It checks each usable link high/low/high, verifies the other lines remain
unchanged, and tests the resistor against both H2 internal pulls. GPIO35 is
only tested as an input. Reserved pins are never driven.

## Toit tests

From the repository root:

```sh
TOIT="$PWD/build/host/sdk/bin/toit"
"$TOIT" run tests/hw/esp-tester/tester.toit -- setup \
  --toit-exe "$TOIT" --port "$H2_PORT" \
  --envelope build/esp32h2/firmware.envelope --control serial
"$TOIT" run tests/hw/esp-tester/tester.toit -- setup \
  --toit-exe "$TOIT" --port "$HELPER_PORT" \
  --envelope build/esp32/firmware.envelope --control serial
```

All H2 suites now run on both boards. The ESP32 is the trusted **tester**;
H2 is the **testee**. For example:

```sh
"$TOIT" run tests/hw/esp-tester/tester.toit -- --toit-exe "$TOIT" run \
  --tester-board2 --port-board1 "$H2_PORT" --port-board2 "$HELPER_PORT" \
  --control serial \
  tests/hw/esp32h2/peripherals.toit tests/hw/esp32h2/peripherals.toit
```

The tester initiates each named case, enforces a deadline, and evaluates its
own electrical observations and the testee's returned measurements/payloads.
Both boards still perform local assertions. Only the tester emits `TESTER PASS`,
after all cases and the final completion handshake; closing resources never
signals success. Case numbers and names reject skipped or out-of-order cases.
The host builds, installs, launches, and records logs. With `--tester-board2`
it requires the tester's verdict, not a success marker from the testee. Its
outer timeout remains a safeguard against a failed tester.

`basics.toit` reports chip identity and RTC size to the tester. `runtime.toit`
reuses the EC618 GC/storage self-tests; these internal checks remain on H2,
with the tester enforcing their sequence, explicit completion, and deadlines.
The existing standalone `tests/hw/esp32/run-time-test.toit` is still available
for runtime accounting and timer deep-sleep retention; it uses the legacy host
runner without `--tester-board2`.

| H2 test | ESP32 tester | Coverage |
| --- | --- | --- |
| `basics.toit` | `basics.toit` | Chip identity, RTC memory size, formatting, collections. |
| `runtime.toit` | `runtime.toit` | H2 GC and storage self-tests supervised by ESP32. |
| `peripherals.toit` | `peripherals.toit` | UART payloads through 4096 bytes; GPIO input/output, open drain, interrupts, pull-up/down; ADC; pulse counter; PWM. |
| `wakeup.toit` | `wakeup.toit` | GPIO10 high and low external wakeup, reset reason, and wake-source mask. |
| `buses.toit` | `buses.toit` | Both SPI roles in all four modes, H2 target DMA through 1024 bytes, both I2C roles, RMT transmit and receive. |
| `i2c-repeated-start.toit` | `i2c-repeated-start.toit` | Long repeated-start transfers at FIFO boundaries and recovery after NACK. |
| `ble.toit` | `ble.toit` | Both BLE roles, advertising/scanning, connection, read/write, notifications, adapter close/reopen. |
| `i2s.toit` | `i2s.toit` | ESP32 verifies 200 KB of I2S data in every role, including raw receive buffers forwarded by H2. |

For I2S, run the paired command with each of these `--arg` values:
`philips16`, `philips16-slave`, `philips16-writer`, and
`philips16-writer-slave`. This covers H2 receive/transmit in both clock roles.
The reused data verifier allows up to 30 stream errors for the known IDF issue documented
in `tests/hw/esp32/i2s-shared.toit`; a pass does not imply an error-free stream.

I2C uses internal pull-ups and tests 50 and 100 kHz. Writes through 1024 bytes
and 32-byte reads are verified with repeated starts in both controller/target
roles. The boundary regression covers writes around the 32-byte controller
FIFO boundaries and verifies recovery after an address NACK. It caught an
ESP-IDF controller bug: the next address could be queued before the preceding
write drained the TX FIFO. ESP-IDF PR
[toitware/esp-idf#134](https://github.com/toitware/esp-idf/pull/134) drains the FIFO
before the repeated START, preserving the combined transaction on the wire.
Use firmware containing that fix for the long repeated-start regression.

UART control uses H2 GPIO2/5 and helper GPIO27/35. The other signals are reused
sequentially; no additional wires are needed. The helper's GPIO35 has no internal
pull-up, which IDF may report when UART initializes; communication is driven by
the H2 GPIO5 output. I2S increases the board-to-board UART to 921600 baud so
forwarding H2 receive buffers keeps up with the audio stream. Other suites use
115200 baud. The I2S writer stops before the tester issues its verdict; there
is no background-writer success shortcut.

## Verdict rejection tests

Run `fault-injection.toit` on both boards with `--tester-board2` and each
`--arg` value: `corrupt`, `silent`, `cleanup`, `skip`, and `crash`.
**Each run must fail**, log a tester-side rejection or timeout, and contain no
`TESTER PASS`. These check that wrong data, a silent testee, cleanup without
completion, skipped work, and a testee crash cannot become success. The three
second case deadline belongs to the ESP32; the host's outer timeout should
not be reached.
