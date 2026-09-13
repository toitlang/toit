# EC618 hardware tests

Hardware-in-the-loop tests for the EC618. Some run standalone on the EC618;
others use an ESP32 helper to drive or observe the wired peripheral signals.

Dual-board tests normally use a pair of files:

- `<name>-ec618.toit` runs on the EC618 device under test.
- `<name>-esp32.toit` runs on the ESP32 helper.

The test files contain the assertions and protocol, not host-specific launch
commands or serial-port names. See
[the EC618 rig guide](../../../docs/ec618-rig-guide.md) for the current way to
identify each board, launch a test, and recover either rig. See
[the hardware-test plan](../../../docs/ec618-hw-tests.md) for the authoritative
wiring and coverage matrix.

Executable tests import their physical signal assignments from
[`wiring.toit`](wiring.toit). Add a function-named signal there instead of
embedding a rig pin number in an individual test.

## Pin identity

Toit identifies an EC618 pin by its physical PAD number. Module silkscreen
labels such as `GPIO22` and `NET_STATUS` are not unique physical identifiers,
and some board contacts mirror the same net. Tests that depend on a particular
wire use the shared wiring data.

The chip-level GPIO/PAD mapping comes from the EC618 CSDK's complete
`allGpioMap` example table and its `GPIO_ToPadEC618` helper. The hardware-test
plan records the separate board-level evidence: which Air780E connector
contact reaches which pad, and which contacts are mirrors of the same net.

The rig uses 3.3 V digital IO on both the EC618 and ESP32. EC618 AIO3/AIO4 are
separate analog inputs; the wired ESP32 DAC signals pass through voltage
dividers.

## Programmable I2C/SPI fixture

The former RC522 and BME280 connections now terminate at an ESP32-S3.
`bus-target-s3.toit` uses the SDK's `i2c.RegisterTarget`, `i2c.Target`, and
`spi.Target`. The classic ESP32 remains connected for UART1 control, ADC,
and GPIO observation. See `wiring.toit` for both sides of every signal.

SPI CS/S3 GPIO7 shares its net with I2C SDA/GPIO12, and SPI MOSI/GPIO5 shares
its net with I2C SCL/GPIO13. Run target roles sequentially. The target fixture
leaves unused aliases unconfigured. Its SPI CLK/MISO nets also connect to
the classic ESP32's UART2 pins: only UART1 may carry control during SPI.

1. Compile `bus-target-s3.toit` with the matching ESP32 SDK, add it as a
   boot-triggered container to an S3 firmware envelope, and flash the dedicated
   S3. Use the octal PSRAM configuration for this board. Its console is the
   host control endpoint; do not install a competing serial mini-jag agent.
2. Run `bus-control-esp32.toit` on the classic ESP32. It prints its network
   address and forwards the independent UART1 lane on TCP port 18561. It also
   enables additional internal pull-ups on the connected I2C1 nets. For a permanent rig, fit external
   pull-ups appropriate to the wiring capacitance; internal pulls are weak.
3. Start the host coordinator (requires Python and pyserial):
   `python3 run-bus-rig.py --bridge <classic-ip> --target-port <verified-serial-port>`.
   It waits for the S3 to boot and relays the existing CRC-protected EC618
   control frames. It never substitutes a verdict for missing target output.
4. Run `bus-controller-ec618.toit` with the EC618 mini-jag tester. The default
   covers I2C, stretching/cancellation, and SPI. Arguments `i2c`, `speed`, `stretch`,
   or `spi` select one group. Restart the coordinator before another run;
   opening the S3 adapter resets the fixture and releases its previous role.

The tests compare both SPI directions, prefixes (including a zero-valued
four-bit command followed by a four-bit address), slice sentinels, all four
SPI modes, I2C write/read/write-read payloads through 1025 bytes, and SPI DMA
through 32768 bytes. Cancellation must release the controller for immediate
reuse. I2C0 remains connected only to the classic ESP32; the S3 tests exercise
I2C1.

To test I2C0, install `bus-target-esp32.toit` as the classic ESP32's standalone
boot container using the same SDK and Wi-Fi configuration. It combines the
UART1 bridge with a basic `i2c.Target` on GPIO18/17. The original ESP32
does not support `RegisterTarget` or response-time stretching; its fixture
uses a fresh target for each read and limits default responses to 32 bytes.
I2C0 checks reads and repeated starts through 32 bytes, and writes through
1025 bytes, at 50/100/400 kHz. Point `--target-port` at
the classic ESP32 console and run the controller with argument `i2c0`.
The S3 must be idle during this run. The I2C0 scan and ownership tests remain
separate; reset the classic fixture to release its target before an empty-bus
scan. Keep the classic console free of a competing mini-jag agent.

`spi-target-ec618.toit` replaces `rc522-ec618.toit`. The former BMP280/BME280
tests and their sensor package dependencies have been removed; the I2C
controller suite verifies actual target data instead of sensor identity and
calibration registers.

The S3 must be reset into the idle fixture before unrelated GPIO/UART tests,
so its bus pins are inputs. Stop the UART1 bridge before tests that own that
lane. `gpio-aon-output-ec618.toit` now runs the consolidated GPIO test with
`gpio-map-esp32.toit`, observing PAD42 directly instead of powering a sensor.
