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

## Toit tests

Install the pixel-strip dependency with `toit pkg install` from `tests/hw`.
Reusable implementations are in [`../paired`](../paired/README.md); these
entrypoints supply the H2/ESP32 wiring and roles. The paired implementations do
not select pins or roles from chip identity. [wiring.toit](wiring.toit) defines
the physical connections and named peripheral assignments; pin numbers stay
in that fixture configuration. Reversing test roles does not change the local
pin assignments.


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

Run the paired wiring pre-check after setup, before the peripheral suites:

```sh
"$TOIT" run tests/hw/esp-tester/tester.toit -- --toit-exe "$TOIT" run \
  --port-board1 "$H2_PORT" --port-board2 "$HELPER_PORT" --control serial \
  tests/hw/esp32h2/check-wiring.toit tests/hw/esp32h2/check-wiring.toit
```

`check-wiring.toit` runs entirely on the two Toit boards. The ESP32 checks
high/low/high on each of the five GPIO links in both directions and verifies
that other GPIO lines stay high. It also checks the resistor against H2 pulls,
using readings from both boards. The two UART links (H2 GPIO2/5 to ESP32
GPIO27/35) are checked through a 256-byte echo; they remain the control channel
and are not exercised as GPIOs. Reserved pins are never driven.

All H2 suites run on both boards. The ESP32 is the trusted **tester**;
H2 is the **testee**. For example:

```sh
"$TOIT" run tests/hw/esp-tester/tester.toit -- --toit-exe "$TOIT" run \
  --port-board1 "$H2_PORT" --port-board2 "$HELPER_PORT" \
  --control serial \
  tests/hw/esp32h2/peripherals.toit tests/hw/esp32h2/peripherals.toit
```

The tester initiates each named case, enforces a deadline, and evaluates its
own electrical observations and the testee's returned measurements/payloads.
Both boards perform local assertions. The tester delays its ordinary
`All tests done` marker until all cases and the final completion handshake
succeed. The testee waits for the tester's acceptance before emitting its own
marker. Closing resources never signals success. Case numbers and names reject
skipped or out-of-order cases. The host runner builds, installs,
launches, records logs, and waits for both boards' completion markers. Its
outer timeout remains a safeguard against a failed board.

`basics.toit` reports chip identity and RTC size to the tester. `runtime.toit`
reuses the portable GC, storage, and formatting tests; these internal checks remain on H2,
with the tester enforcing their sequence, explicit completion, and deadlines.
The existing standalone `tests/hw/esp32/run-time-test.toit` is available
for runtime accounting and timer deep-sleep retention; it uses the same host
runner with a single board.

| H2 test | ESP32 tester | Coverage |
| --- | --- | --- |
| `check-wiring.toit` | `check-wiring.toit` | Wiring pre-check: UART, GPIO links and unintended changes on other lines, resistor/pulls. |
| `basics.toit` | `basics.toit` | Chip identity, RTC memory size, formatting, collections. |
| `runtime.toit` | `runtime.toit` | GC, storage including multipage flash values, and floating-point formatting supervised by ESP32. |
| `regressions.toit` | `regressions.toit` | PWM waveforms/endpoints/lifecycle; UART duplex, framing and gap detection; GPIO release/ownership/edge waits; PCNT filtering; UART pixel-strip waveforms; optional RMT timing failure reproducer. |
| `peripherals.toit` | `peripherals.toit` | UART payloads through 4096 bytes; GPIO input/output, open drain, interrupts, pull-up/down; ADC. |
| `wakeup.toit` | `wakeup.toit` | GPIO10 high and low external wakeup, reset reason, and wake-source mask. |
| `buses.toit` | `buses.toit` | SPI roles/modes and DMA boundaries through 4092 bytes, target cancellation/reuse; I2C roles and buffer guards; RMT transmit/receive and long output. |
| `i2c-repeated-start.toit` | `i2c-repeated-start.toit` | Long repeated-start transfers at FIFO boundaries and recovery after NACK. |
| `ble.toit` | `ble.toit` | Both BLE roles, descriptors, repeated writes/notifications through 200 bytes, adapter close/reopen. |
| `i2s.toit` | `i2s.toit` | ESP32 verifies 200 KB of I2S data in every role, including raw receive buffers forwarded by H2. |

Run `regressions.toit` on both boards. With no `--arg` it runs all selected
passing regressions; `--arg pwm`, `uart`, `gpio`, or `pixels-uart` selects one
family. `--arg pixels-rmt` reproduces the RMT pixel-strip timing failure;
`--arg pixels` runs both backends. `--arg pwm-reverse` runs the
same PWM checks with ESP32 as testee and H2 as observer.
PWM checks physical high/low durations and absence of edges at 0%/100%.
UART tests include deliberately inserted pauses to validate gap detection.
See the shared suite README for timing thresholds and coverage limits.

For I2S, run the paired command with each of these `--arg` values:
`philips16`, `philips16-slave`, `philips16-writer`, and
`philips16-writer-slave`, `msb32-slave`, and `msb32-writer`. The Philips cases
cover H2 receive/transmit in both clock roles; the MSB cases check 32-bit data
in both directions. Additional `msb32`, `pcm16-writer`, and
`pcm16-writer-slave` arguments reproduce format/clock-role issues; see the
shared README before including them in a passing regression run.
The reused data verifier allows up to 30 stream errors for the known IDF issue documented
in `tests/hw/esp32/i2s-shared.toit`; a pass does not imply an error-free stream.

I2C uses internal pull-ups and tests 50 and 100 kHz. Writes through 1024 bytes
and 32-byte reads are verified with repeated starts in both controller/target
roles. The boundary regression covers writes around the 32-byte controller
FIFO boundaries and verifies recovery after an address NACK. The controller must drain the preceding write from its TX FIFO before queuing
the next address. ESP-IDF PR
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

Run `fault-injection.toit` on both boards with each
`--arg` value: `corrupt`, `silent`, `cleanup`, `skip`, and `crash`.
**Each run must fail** and neither board may emit `All tests done`. These check
that wrong data, a silent testee, cleanup without completion, skipped work, and
a testee crash cannot become success. Both boards enforce a three second case
deadline. The host can report either board's error first; its
outer timeout should not be reached.
