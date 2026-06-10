# EC618 hardware tests

Hardware-in-the-loop tests for the EC618. Some run standalone on the EC618 (via
the mini-jag tester); others need a second board to drive/observe signals.

For the dual-board tests the second board is an **ESP32** running Jaguar, wired
to the EC618 as described below. Each dual-board test is split in two files:

- `<name>-ec618.toit` — runs on the EC618 (the device under test), launched with
  the mini-jag tester over serial.
- `<name>-esp32.toit` — runs on the ESP32 (the helper that drives or checks the
  signal), launched with Jaguar over WiFi.

## Boards and ports

| Board | Bridge | Serial port | Driven by |
|-------|--------|-------------|-----------|
| EC618 (device under test) | CH340 | `/dev/ttyUSB1` (= EC618 UART0, console + mini-jag control) | `tests/hw/esp-tester/tester.toit run --chip ec618` |
| ESP32 (helper, `modest-affair`) | CP2102N | `/dev/ttyUSB0` (console) | `jag run ... --device modest-affair` |

## Wiring (ESP32 GPIO ↔ EC618 board pin)

The EC618 module's silkscreen / datasheet pin *labels* (e.g. `GPIO22`,
`NET_STATUS`) are **Air780-module names and do not match the EC618 GPIO
controller-bit numbers** that the `ec618` Toit library uses. So the physical
pad behind each board pin has to be confirmed **experimentally** (toggle it,
see which ESP32 pin moves). Two board pins are even labelled "GPIO11" and two
"GPIO10": that is because one GPIO controller bit can surface on two pads (e.g.
GPIO11 = PAD26 *and* PAD22), which is the clue for telling them apart.

```
ESP32 pin   EC618 board pin (label)              EC618 pad (confirmed / candidate)
---------   ----------------------------------   ---------------------------------
25 (DAC1) -> [voltage divider] -> ADC0 (pin 3)    ADC ch0  (~1.8 V max; see ADC tests)
26 (DAC2) -> [voltage divider] -> ADC1 (pin 4)    ADC ch1  (one ADC pin may be dead)
27        -> 05  (GPIO11, uart2_txd)              PAD26  (GPIO11 primary)   [confirmed]
14        -> 06  (GPIO10, uart2_rxd)              PAD25  (GPIO10 primary)
13        -> 09  (GPIO22, MAIN_DTR)               IO13 is the BMP280 power switch; pin 9 appears UNWIRED (PAD42 drives don't reach it)
33        -> 10  (GPIO08, SPI0_CS, I2C1_SDA)      PAD23  (GPIO8)            [confirmed]
32        -> 11  (GPIO10, UART2_RX, SPI0_MISO)    mirrors PAD25's net (gpio-map)
23        -> 12  (GPIO01, PWM10)                  PAD16  (TIMER0 PWM out)   [confirmed]
22        -> 13  (GPIO09, I2C1_SCL, SPI0_MOSI)    PAD24  (GPIO9)            [confirmed]
21        -> 14  (GPIO11, UART2_TX, SPI0_CLK)     mirrors PAD26's net (NOT PAD22)
19        -> 18  (GPIO24, MAIN_RI, PWM01)         PAD44  (GPIO24, AON)      [confirmed]
18        -> 22  (I2C0_SDA)                       PAD14  (GPIO15 alt4 / I2C0 SDA)  [confirmed]
17        -> 23  (I2C0_SCL)                       PAD13  (GPIO14 alt4 / I2C0 SCL)  [confirmed]
 2        -> 27  (GPIO27, NET_STATUS, PWM04)      PAD47  (GPIO27, AON)      [confirmed]
 4        -> 30  (UART1_TXD)                       UART1 TX (PAD34)
16        -> 31  (GPIO18, UART1_RXD, PWM14)        UART1 RX (PAD33)
```

Notes:
- EC618 IO is ~1.8 V; the ESP32 (3.3 V) reads it as a valid logic high, so
  EC618→ESP32 GPIO works directly (no level shifter). The reverse direction
  (3.3 V into the EC618) should go through a divider — only the ADC lines have
  one, so prefer EC618→ESP32 unless a pin is known to be 3.3 V tolerant.
- The ADC inputs are limited to ~1.8 V; the ESP32 DACs (0–3.3 V) therefore feed
  the EC618 through a voltage divider.
- The AON-domain pads (40..48 = GPIO20..28, the "red" pins) are dead until the
  AON IO LDO is powered (`slpManAONIOPowerOn`, done by the GPIO driver on
  open). With power they drive normally: PAD44 and PAD47 confirmed. PAD42
  (board pin 9) found no wire — IO13 doubles as the BMP280 power switch, so
  pin 9 looks disconnected on this rig.
- Pads 13/14 carry GPIO14/15 at iomux FUNCTION 4 (not 0) — the SDK's
  example_gpio table is the authoritative GPIO/pad/mux source. Pads 29/30
  (UART0) have no GPIO function; as Pins they are carriers only.

## Running a dual-board test

The two halves are launched independently and coordinate by signal + timing
(the helper waits a generous window for the device under test to start). For an
EC618-drives / ESP32-checks test:

```sh
TOIT=build/host/sdk/bin/toit

# 1. Capture the ESP32 console.
jag monitor -a --port /dev/ttyUSB0 > /tmp/jag_log 2>&1 &

# 2. Start the ESP32 checker (returns after upload; it then waits for activity).
jag run tests/hw/ec618/<name>-esp32.toit --device modest-affair

# 3. Drive from the EC618 (blocks while it runs).
$TOIT tests/hw/esp-tester/tester.toit run --chip ec618 --toit-exe $TOIT \
    --port-board1 /dev/ttyUSB1 tests/hw/ec618/<name>-ec618.toit

# 4. Read the ESP32 verdict.
grep -i "<name>-esp32:" /tmp/jag_log
```

The EC618 half passes when its container exits cleanly (mini-jag verdict); the
ESP32 half prints a `... PASS`/`... FAIL` verdict line to its console.

## Tests

- `gpio-output-{ec618,esp32}` — EC618 drives GPIO11 (PAD26, board pin 5) as a
  square wave; the ESP32 (IO27) counts edges. Confirms EC618 GPIO output.
- `uart2-echo-{ec618,esp32}` — exhaustive UART2 round-trip: the EC618 sweeps
  9600..4 MHz in both reopen and set-baud modes, telling the ESP32 each baud
  over the control lane (UART1 TX → IO4); the ESP32 echoes on UART2.
- `uart2-bigdata-{ec618,esp32}` — throughput/keep-up + leak test: 256 KiB per
  direction per baud as a deterministic CRC'd stream, never echoing (neither
  side reads and writes at once). Diagnoses RX loss with max-read, first-bad
  offset, and the driver error counter. 4 MBd RX currently FAILS — see
  `docs/ec618-known-issues.md` #4.
- `uart2-ring-ec618` (uses the `uart2-bigdata-esp32` helper) — locks in the
  measured PLAT driver RX-ring behavior: 32 KiB capacity, silent discard-ALL
  on overflow, no error callback, and RX dead-until-reopen after one overflow.
- `uart2-duplex-ec618` (uses the `uart2-bigdata-esp32` helper's `D` command) —
  full-duplex stress: 256 KiB each way simultaneously. Currently FAILS on the
  RX side via the overflow-wedge — see `docs/ec618-known-issues.md` #4.
- `uart2-config-{ec618,esp32}` — full configuration matrix: data bits 5..8 ×
  parity none/even/odd × stop bits 1/2 (+ a 1.5-stop probe) at 115200 and
  921600, plus a deliberate parity mismatch verifying the error counter
  (one error per bad byte; bytes still delivered). PASSES.
- `uart2-rs485-{ec618,esp32}` — RS485 half-duplex: UART2 in
  `MODE-RS485-HALF-DUPLEX` with the direction (DE) line on PAD33, observed by
  the ESP32 on IO16. Verifies exactly one DE pulse per message, DE released
  right after the last bit (including a 4 KiB message), and DE low while the
  peer transmits, at 9600/115200/921600. PASSES.
- `uart2-flush-ec618` (standalone, no helper board) — flush semantics by
  timing: `out.flush` / `write --flush` returns no earlier than the payload's
  wire time and not much later, at 9600/115200/921600; plus no-garbage-on-open
  and `--break-length` rejection. PASSES.
- `rc522-ec618` (standalone) — SPI0 against a real MFRC522 v2 RFID reader:
  version register, 64-byte FIFO loopbacks, soft power-down cycling; the
  reader sits in hard power-down (RST on PAD16, external pull-down) outside
  this test. `rc522-probe-esp32` checks the wiring from the ESP32 side.
  PASSES.
- `bmp280-{ec618,esp32}` — I2C against a real BMP280 on I2C1 (pads 23/24,
  board pins 10/13; sensor power switched by the ESP32 on IO13): scan,
  NACK probing, chip-id, forced measurements with datasheet compensation,
  and the `bmp280` package driver. PASSES. (`bme280-probe-esp32` is the
  ESP32-side hookup checker.)
- `gpio-opendrain-{ec618,esp32}` — GPIO open-drain emulation as a real
  two-master wired-AND bus (PAD33 <-> IO16, both open-drain, pull-ups both
  sides): drive/release, wire readback, the wired-AND property, toggling,
  live `set-open-drain` flips, and the no-internal-pull-up configuration
  (external pull-up only, with a released-pin high-Z proof). PASSES.
- `gpio-interrupt-{ec618,esp32}` — GPIO interrupts: the ESP32 drives pulse
  trains into PAD26; the EC618 counts them with `Pin.wait-for` (the
  interrupt path, not polling) — exact counts at 50 Hz and 250 Hz, plus a
  no-spurious-wakeup check on a quiet line. PASSES.
- `pwm-{ec618,esp32}` — PWM (generic `gpio.pwm` API): frequency via ESP32
  pulse counter, duty by polling, constant extremes, live set-frequency, two
  simultaneous channels (PAD33/TIMER4 -> IO16, PAD16/TIMER0 -> IO23), closed
  channel goes silent. The ESP32 half is a dumb measurement server commanded
  over UART2; all assertions run on the EC618. PASSES.
