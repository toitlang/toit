# EC618 hardware tests

Hardware-in-the-loop tests for the EC618. Some run standalone on the EC618;
others use an ESP32 helper to drive or observe the wired peripheral signals.

Dual-board tests normally use a pair of files:

- `<name>-ec618.toit` runs on the EC618 device under test.
- `<name>-esp32.toit` runs on the ESP32 helper.

The test files contain the assertions and protocol, not host-specific launch
commands or serial-port names. See
[the EC618 rig guide](../../../docs/ec618-rig-guide.md) for the current way to
identify each board, launch a test, and recover either rig. The same guide
records the wiring and regression groups.

Executable tests import their physical signal assignments from
[`wiring.toit`](wiring.toit). Add a function-named signal there instead of
embedding a rig pin number in an individual test.

## CTest with a resident agent

Configure `tests/hw` with `TOIT_EXE_HW` matching the installed firmware,
`EC618_BOARD_PORT` set to its persistent UART0 path, and `EC618_EXPECT_BASE`
set to its exact base identity. Enable `EC618_TEST_STANDALONE` for basics,
ADC/cellular lifecycle and events, watchdog-stop and integer-width tests.
`EC618_TEST_FPC` adds I2S allocation and stop tests. Enable
`EC618_TEST_I2S_MASTER` only with DS18B20 disconnected and peer clock pins
left as inputs; it adds the live-clock stop test.

Run `ctest --test-dir <hardware-build> -C ec618 -L standalone --output-on-failure`.
The Toit runner takes the shared rig lock through `flock`, checks the base
identity and non-trial slot before each test, and checks health afterward.
Failure triggers cancellation and a bounded recovery wait; successful
recovery does not turn a failed test into a pass. It never flashes firmware.
This standalone label does not cover coordinated bus payload matrices.

For the breakout matrix, provision `fpc-target-s3.toit` on the S3 and run
the classic ESP32 UART1 bridge. Configure `EC618_TEST_BUSES=ON`,
`EC618_BUS_TARGET_PORT` and `EC618_BUS_BRIDGE`, then run CTest with
`-C ec618 -L fpc-bus`. The four cases cover concurrent I2C0/I2C1, both
alternate UART2 routes and SPI. `run-ec618-bus.toit` requires the exact
`FPC-BUS-1` fixture identity, a complete case-specific controller verdict,
and successful framed relay completion. It resets the target to idle and
checks EC618 health after each case. CTest retains controller and relay
output together. The bus and paired-I2S options require different resident
S3 firmware and cannot be enabled together. These Toit runners do not add
a Python dependency or provision either board.

## Paired I2S tests

The three CMake options `EC618_TEST_I2S_RX`, `EC618_TEST_I2S_TX` and
`EC618_TEST_I2S_DUPLEX` select different resident S3 fixtures:
`i2s-source-s3.toit`, `i2s-sink-s3.toit` and `i2s-duplex-s3.toit`, respectively.
Enable only one option per build directory. Preserve the original S3 image
before provisioning a fixture, disconnect DS18B20 DQ from the shared clock
net, and verify the physical assignments in `wiring.toit`.

Configure `tests/hw` with `TOIT_EXE_HW` pointing to the compiler matching the
installed EC618 firmware, `EC618_BOARD_PORT` and `EC618_I2S_PEER_PORT` set to
verified persistent serial paths, and `EC618_EXPECT_BASE` set to the expected
base identity. Configuration and `ctest --show-only` do not provision boards.
The runner requires the corresponding resident fixture and uses the shared
rig lock. For example, after configuring receive tests:

```sh
ctest --test-dir <hardware-build> -C ec618 -L i2s-rx --output-on-failure
```

The current matrices register 94 receive, 30 transmit and 12 duplex cases.
These counts include the 96-kHz configurations; registration is not evidence
that every case passes. The verifier checks distinct channel patterns and
never resynchronizes after a payload mismatch. Startup allowances in the
S3 fixture do not qualify first-frame fidelity. Duplex checks both directions
for two seconds by default, rather than establishing indefinite streaming.
ESP32/S3 I2S has known failures listed in `../esp32/fail.cmake`, so a peer
failure alone does not identify the EC618 as the faulty endpoint.

The October 14 supported-endpoint run passes all six receive and six
transmit cases, and five of six duplex cases. The remaining failure is
96-kHz/24-bit EC618-master duplex at the S3 receiver; the reverse EC618
capture passes. Native S3 diagnostics reproduce the corruption without
the S3 Toit runtime. Independent SPI captures, aligned using BCLK counts
and checked against native DMA frame counts, contain correct data at two
frames corrupted by native I2S receivers, across separate runs using
opposite SPI sampling edges. This narrows the failure to receiver behavior
or electrical timing; it does not qualify all frames or establish timing
margins. Keep this duplex case failing until it is resolved or independently
qualified; do not skip it or treat clean sampled windows as a full pass.

Subsequent independent SPI captures verify over two consecutive seconds of
96-kHz/24-bit EC618 output on each sampling edge while the reverse EC618
capture verifies ten seconds, with zero capture overruns/underruns. The SPI
observer rejects a deliberate 100-ms consumer stall after its first DMA
block, then passes a full capture without reflashing. This provides bounded
continuous duplex qualification beyond the earlier sampled windows. Native
S3 receiver failures remain intermittent; one clean recovery run does not
establish a fix. The independent results do not qualify indefinite streaming,
first-frame fidelity or electrical timing margins.

The [independent SPI observer](i2s-spi-observer/README.md) contains the pinned
native fixture, Toit runner, exact-stream checks and host fault tests needed
to reproduce these independent observations without patching the shared SDK.

On the integrated v5 base, two default-buffer 96-kHz/24-bit duplex runs
also fail at the EC618 endpoint, with underruns and overruns. These failures
cannot be assigned solely to the S3 receiver. Subsequent repeats pass the
complete independent SPI capture on both sampling edges and the ten-second
EC618 capture; one also passes both native S3 receivers. The intermittency
remains unresolved. A compiler-control comparison produces byte-identical
32-bit test images, ruling out changed test code as its explanation.

Before packed 24-bit storage, the default ring holds about 43 ms per
direction and an explicit 100-ms duplex request needs 153600 ring bytes.
That request fails with `MALLOC_FAILED`, even after correcting the thread
stack-size units. All allocation-failure runs recover to a healthy agent.

Packed 24-bit software rings use 32640 bytes by default (about 56 ms at
96 kHz) and 115200 bytes total for 100-ms duplex. DMA buffers remain unpacked.
The halfword-plus-byte implementation passes independent continuous SPI
capture on both sampling edges with both default and 100-ms buffers; all
four reverse EC618 captures verify ten seconds with zero over/underruns.
Both mode-1 cases also pass native S3 receive; both mode-0 cases fail there.
An earlier bytewise packed implementation failed all four EC618 streaming
cases. These bounded results establish usable 100-ms buffers on this rig,
but do not establish a cure for the intermittent service stalls.
Evidence is recorded in `docs/ec618-todo.md`, including failed attempts.

EC618 Datasheet V1.3, section 7.5 specifies up to 96 kHz for 16/24-bit
samples and 48 kHz for 32-bit samples. The driver rejects higher 32-bit
rates in both roles, including explicit buffer-duration configurations.
The manufacturer-authored document was consulted through a
[third-party mirror](https://www.scribd.com/document/1060340987/EC618-Datasheet-V1-3),
not a manufacturer-hosted PDF. Historical 96-kHz/32-bit diagnostics do not
qualify supported operation.

EC618's default software ring targets 200 ms, capped at 32768 bytes per
direction with a minimum of 512 stereo frames. An explicit
`--buffer-duration-ms` value from 1 through 1000 bypasses the default byte
cap and can fail allocation. High-rate wide samples therefore have less than
200 ms of default buffering. Buffer-allocation and stop/restart tests do not
substitute for exact live payload checks.

## Cellular notifications and lifecycle

After configuring an EC618 build, run the notification regression on the host:

```sh
cmake -P tests/hw/ec618/run-cellular-state-test.cmake
```

The runner reads vendor header paths and definitions from
`build/ec618/compile_commands.json`. Set `-DCOMPILE_COMMANDS=<path>` before
`-P` to use another build, or `-DCXX=<path>` to select a host C++ compiler.
It checks truncated and unaligned notification payloads, attach/detach
ordering, disconnect causes and IPv4 validity using the actual vendor types.
It requires neither a SIM nor radio access.

Run `cellular-lifecycle-ec618.toit` on EC618 to check exclusivity, ownership,
disconnect-reason access and release/reacquisition. A run with argument `leak`,
followed by a normal run, checks cleanup after container exit. These lifecycle
checks do not require network attachment. Network tests require a working SIM
and cellular coverage; passing host tests does not qualify network operation.

## Dedicated 1-Wire controller

The native controller provides standard-speed reset, bit and byte operations
on PAD19 (mux 3), or PAD17/22/48 (mux 4). It permits one owner at a time and
reserves the selected pad. Strong pull-up is not supported. The separate
`one-wire.hardware` package backend supplies ROM search, CRC, serialization
and deadline/cancellation cleanup; the ordinary portable package import does
not require these new native primitives.

Recorded hardware qualification covers PAD19: DS18B20 ROM search and conversion
CRC, deadline abort, task cancellation, cross-container ownership and cleanup
after normal exit or forced stop. This does not qualify PAD17/22/48. Portable
package and unsupported-backend host tests do not replace sensor tests.
The hardware backend requires a supporting SDK release before publication.

Disconnect DS18B20 DQ before I2S tests that drive the shared PAD19 clock net.
When testing 1-Wire, leave the connected peer pin as an input and use the
sensor wiring and pull-up recorded in the rig guide.

## Pin identity

Toit identifies an EC618 pin by its physical PAD number. Module silkscreen
labels such as `GPIO22` and `NET_STATUS` are not unique physical identifiers,
and some board contacts mirror the same net. Tests that depend on a particular
wire use the shared wiring data.

The chip-level GPIO/PAD mapping comes from the EC618 CSDK's complete
`allGpioMap` example table and its `GPIO_ToPadEC618` helper. The rig guide
records the separate board-level evidence: which Air780E connector
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
3. Install the host coordinator's dependencies with `toit pkg install` in this
   directory, then start it:
   `toit run run-bus-rig.toit -- --bridge <classic-ip> --target-port <verified-serial-port>`.
   It waits for the target to boot and relays the existing CRC-protected EC618
   control frames. It never substitutes a verdict for missing target output.
4. Run `bus-controller-ec618.toit` with the EC618 mini-jag tester. The default
   covers I2C, stretching/cancellation, and SPI. Arguments `i2c`, `speed`, `stretch`,
   or `spi` select one group. Restart the coordinator before another run;
   the coordinator resets the target over RTS and releases its previous role.

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
