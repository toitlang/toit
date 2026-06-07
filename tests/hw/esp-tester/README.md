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

The EC618's UART1 is both the console and the control channel; connect it to a
host serial port (e.g. `/dev/ttyUSB0`). Flashing goes over the chip's boot ROM,
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

Each EC618 test runs under the hardware watchdog so a hang or a crash recovers
the device on its own — no external reset needed. `mini-jag` arms the watchdog
before starting the test container and feeds it from a separate task for up to a
~3-minute budget. The hardware timer maxes out at 60 s, hence the feed-from-a-task
approach. If the test exits first the watchdog is stopped; if it hangs past the
budget — or wedges the whole device, taking the feeder task down with it — the
feeding stops and the watchdog resets the chip, which reboots straight back into
the resident agent. The host notices the agent's fresh boot banner mid-run and
reports the test as a failed run that the watchdog recovered.
