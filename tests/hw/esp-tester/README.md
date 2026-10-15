# mini-jag test runner

A tiny "Jaguar-like" harness for running hardware tests on a device from the
host. It has two parts:

- [mini-jag.toit](mini-jag.toit) — runs *on the device*. It receives a test
  container from the host, runs it, and lets the test's output stream back.
- [tester.toit](tester.toit) — runs *on the host*. It builds the test, drives
  the device, and reports pass/fail.

The control protocol shared by the two lives in [shared.toit](shared.toit).

## Transports

The harness supports two very different targets:

- **ESP32** (`--chip esp32`, the default). The control channel runs over
  TCP/Wi-Fi: the host resets the board over DTR/RTS, reads the serial console to
  discover the device's IP, then connects and sends the test image and a run
  signal. The test's `print` output comes back over the serial line.

- **EC618** (`--chip ec618`). There is no Wi-Fi and (in our rig) no host reset
  line, so the *whole* control channel runs over the device's single print
  UART. `mini-jag` runs a **resident agent**: it never reboots itself between
  tests; a test runs as a child container whose output streams back on the same
  wire. Protocol bytes are interleaved with the agent's `[mini-jag] ...` status
  lines; the host tells them apart (every status line starts with `[`, every ack
  is a single non-`[` byte). See [shared.toit](shared.toit) for the wire format.

## EC618 usage

The EC618's UART0 is both the console and the control channel; connect it to a
host serial port (e.g. `/dev/ttyUSB1`). Flashing goes over the chip's boot ROM,
which requires power-cycling the board into download mode (board-specific) while
`setup` runs; `ECTOOL_PATH` must point at `ectool`.

```sh
TOIT=build/host/sdk/bin/toit

# 1. Flash the mini-jag firmware. `setup` builds an envelope with the agent and
#    flashes it over the boot ROM, so trigger boot/download mode while it runs.
$TOIT tests/hw/esp-tester/tester.toit setup \
    --chip ec618 --toit-exe $TOIT \
    --port /dev/ttyUSB0 --envelope build/ec618/firmware.envelope

# 2. Run a test. The device must be booted into the resident agent.
$TOIT tests/hw/esp-tester/tester.toit run \
    --chip ec618 --toit-exe $TOIT \
    --port-board1 /dev/ttyUSB0 tests/hw/ec618/basics.toit

# 3. Update the firmware over the air. Builds the canonical OTA image (with the
#    agent embedded), streams it to the inactive slot via the standard
#    system.firmware FirmwareWriter, trial-boots it, and validates it.
#    Pass --no-validate to leave it unconfirmed (the next reset rolls back).
$TOIT tests/hw/esp-tester/tester.toit firmware-update \
    --toit-exe $TOIT \
    --port /dev/ttyUSB0 --envelope build/ec618/firmware.envelope
```

A test passes when its container exits cleanly (exit code 0); an uncaught
exception (e.g. a failed `expect`) exits non-zero and fails the run. `setup` is
not yet wired into CTest for the EC618 because flashing needs a rig-specific
boot-ROM trigger.

## Watchdog recovery (EC618)

The resident `mini-jag` agent runs under the application watchdog for its
whole life, so a hang or a crash recovers the device on its own — no external
reset needed (which matters on a rig with no remote reset). A test runs in the
**background**, so the command loop keeps reading the UART while the host pings.
If those pings stop for 15 s, the agent stops the test container first. That is
the normal recovery path: stopping the process runs Toit `finally` blocks and
native resource destructors, leaving peripherals and pads reusable.

The agent also arms the watchdog at startup with a 60 s timeout and feeds it on
**every host message**. If the agent stops servicing messages — its read loop
wedged, the VM hung, or an interrupt storm prevents the lease task from running
— the feeds stop and the watchdog resets the chip into a fresh agent. The host
notices the fresh boot banner mid-run and reports a failed run that recovered.
The generous 60 s window also gives a freshly OTA'd agent time to reconnect
without boot-looping the trial slot.

## Paired EC618 I2S fixtures

Use `tests/hw/esp-tester/run-ec618-i2s.toit` with a resident EC618 test agent
and the matching S3 peer: `i2s-source-s3.toit` for receive,
`i2s-sink-s3.toit` for transmit, or `i2s-duplex-s3.toit` for duplex.
The runner checks peer identity and the EC618 base identity and trial status.
It installs test containers, but does not flash either board.

Wiring is recorded in `tests/hw/ec618/wiring.toit`. Disconnect DS18B20 DQ
from the SCK net before running. Use persistent serial paths and hold the
shared rig lock for the whole invocation. From the repository root:

```sh
flock -n /tmp/toit-ec618-rig.lock \
  build/host/sdk/bin/toit run tests/hw/esp-tester/run-ec618-i2s.toit -- \
  --port <EC618-UART0-path> --peer-port <S3-console-path> \
  --toit-exe build/host/sdk/bin/toit --expected-base <deployed-base-id> \
  --direction duplex --case 16000,16,0,master,0 --sensor-disconnected
```

The case fields are sample rate, sample width, format, EC618 role and slots.
Formats are Philips=0, MSB=1 and PCM-short=2; duplex requires stereo slots=0.
Optional duplex settings are `--buffer-duration-ms 1..1000` and
`--capture-seconds 1..10` (default two seconds). The runner requires payload
verification on both receivers for duplex, checks error counters, stops the
peer and performs a final EC618 health check. Failure and cancellation also
attempt bounded cleanup; a recovered board does not turn a failed test into
a pass.

For transmit-only throughput checks, `--tx-no-stall` selects default bounded
buffering and removes the deliberate 150 ms master-side producer pause.
Without this flag, the existing stall test requests 200 ms buffering above
16 kHz; that allocation can exceed EC618 RAM at high rates and sample widths.
Both modes retain strict payload and error-counter verification.

To register the paired matrix with CTest, configure `tests/hw` with
`TOIT_EXE_HW`, `EC618_BOARD_PORT`, `EC618_I2S_PEER_PORT` and
`EC618_EXPECT_BASE`, plus exactly one of `EC618_TEST_I2S_RX=ON`,
`EC618_TEST_I2S_TX=ON` or `EC618_TEST_I2S_DUPLEX=ON`. Enabling a matrix
confirms that DS18B20 DQ is disconnected. Set `EC618_RIG_LOCK` to override
the shared lock path. Run `ctest --test-dir <build-directory> -C ec618
-L i2s --output-on-failure`. Receive registers 96 cases, transmit 30 and
duplex 14; each case performs its own preflight and final health checks.
Each direction includes 96-kHz Philips stereo at 16/24/32 bits in both
clock roles. High-rate transmit cases use `--tx-no-stall` and default buffering.
Registration is not a claim of hardware qualification: the 96-kHz wide-sample
cases retain known payload failures under investigation. Keep those failures
visible; a passing lower-rate subset does not qualify the complete matrix.
Where the broader EC618 suite is present, its setup/cleanup fixtures also run.
The paired matrix does not require Python.

Host regressions are `tests/i2s-pattern-test.toit`,
`tests/i2s-stream-verifier-test.toit`, `tests/i2s-run-output-test.toit` and
`tests/i2s-coordinator-test.toit`. These cover payload verification, split
output, failed stages and cancellation without connecting to hardware.
ESP32 I2S has known failures referenced in `tests/hw/esp32/fail.cmake`;
a paired failure alone does not identify which endpoint is faulty.
