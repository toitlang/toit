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

## Pin identity

Toit identifies an EC618 pin by its physical PAD number. Module silkscreen
labels such as `GPIO22` and `NET_STATUS` are not unique physical identifiers,
and some board contacts mirror the same net. Tests that depend on a particular
wire should state the EC618 PAD, board contact, and ESP32 GPIO in their protocol
or shared wiring data.

The rig uses 3.3 V digital IO on both the EC618 and ESP32. EC618 AIO3/AIO4 are
separate analog inputs; the wired ESP32 DAC signals pass through voltage
dividers.
