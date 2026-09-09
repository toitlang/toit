// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

MINI-JAG-LISTENING ::= "MINI-JAG LISTENING"
RUN-TEST ::= "RUN TEST"
INSTALLED-CONTAINER ::= "INSTALLED CONTAINER"
RUNNING-CONTAINER ::= "RUNNING INSTALLED CONTAINER"

// ----------------------------------------------------------------------------
// Serial (single-UART) mini-jag protocol.
//
// The ESP32 mini-jag can use either TCP/Wi-Fi or its console UART for control.
// The EC618 has neither Wi-Fi nor a host reset line in our rig, so its whole
// control channel always uses the device's print UART. Protocol bytes are
// therefore interleaved with the device's own
// human-readable `[mini-jag] ...` status lines (and the firmware's `[toit] ...`
// lines). The host disambiguates with one rule: every status line starts with
// '[' and ends with '\n'; every protocol ack is a single byte that is never
// '[' (nor a stray CR/LF). See $MINI-JAG-TAG.
//
// The device runs a resident agent (it never reboots itself between tests), so
// the host drives every step request/ack — there is no flow control on the
// shared UART, and the explicit acks both pace the transfer and give a clear
// progress signal.

// Host -> device commands.
CMD-PING       ::= 'P'  // -> ACK-PONG.
CMD-ARG        ::= 'A'  // <len:4 LE><bytes>          -> ACK-OK.
CMD-INSTALL    ::= 'C'  // <size:4 LE><crc:4><bytes>  -> ACK-OK / ACK-ERROR.
CMD-RUN        ::= 'R'  // (no ack) the test's console output then streams.
CMD-RUN-EMBEDDED ::= 'E'  // (no ack) run a named slot-embedded test.
CMD-CANCEL     ::= 'Q'  // -> ACK-OK, then stop the running test container.
CMD-FW-BEGIN   ::= 'F'  // <size:4 LE>                -> ACK-OK / ACK-ERROR.
CMD-FW-WRITE   ::= 'W'  // <len:4 BE><bytes>          -> ACK-READY then ACK-OK / ACK-ERROR.
CMD-FW-COMMIT  ::= 'M'  // <sha256:32>                -> ACK-OK / ACK-ERROR.
CMD-FW-UPGRADE ::= 'U'  // -> ACK-OK, then the device reboots into the trial slot.
CMD-TRIAL      ::= 'T'  // -> ACK-TRIAL-YES / ACK-TRIAL-NO.
CMD-VALIDATE   ::= 'V'  // -> ACK-OK.
CMD-ROLLBACK   ::= 'Z'  // -> ACK-OK, then the device reboots back to the good slot.
CMD-BAUD       ::= 'B'  // <baud:4 LE> -> ACK-OK at the OLD baud, then both sides switch.
                        // The device returns to 115200 on reboot, so a handshake
                        // always starts at 115200.

// Device -> host acks. Single bytes, none of which is '[' (the status-line
// lead-in) or a CR/LF, so the host can always tell an ack from interleaved
// status text.
ACK-PONG       ::= 'P'
ACK-OK         ::= 'K'
ACK-READY      ::= 'R'
ACK-ERROR      ::= 'X'
ACK-TRIAL-YES  ::= 'Y'
ACK-TRIAL-NO   ::= 'n'

// Lead-in for every device status line. The host prints these to its own log
// (so the device's `[mini-jag] ...` and the firmware's `[toit] ...` chatter
// shows up) and otherwise ignores them.
MINI-JAG-TAG ::= "[mini-jag]"
// Status line emitted once the EC618 resident agent is listening.
MINI-JAG-EC618-READY ::= "[mini-jag] ec618 ready"

// A test prints this immediately before a deliberate EC618 deep-sleep reboot.
// The host then treats the next mini-jag ready line as the test verdict and
// compares its `wake=` field with the value after this prefix.
EC618-EXPECT-REBOOT-WAKE-TAG ::= "[ec618-test] expect-reboot-wake="

// Name of the long-running keep-alive container the EC618 envelope installs
// alongside the agent. It keeps the VM scheduling (never EXIT_DONE / deep sleep,
// which would gate the watchdog and brick a no-remote-reset rig) even if the
// agent crashes. The host's envelope build adds it under this name; the agent
// spares it in clear-containers and skips it in run-installed (it is not a test).
SLEEPER-NAME ::= "sleeper"

// A test prints this marker (followed by a payload) to ask the tester to
// write the payload back over the serial connection. Used by tests that
// exercise console UART input.
UART-INPUT-REQUEST ::= "UART-INPUT-REQUEST: "
// A test prints this marker followed by a baud rate to ask the tester to
// acknowledge at the current rate and then switch the serial connection.
UART-BAUD-RATE-REQUEST ::= "UART-BAUD-RATE-REQUEST: "
UART-BAUD-RATE-ACK ::= "UART-BAUD-RATE-ACK"
// At the new rate the host sends SYNC and the testee answers SYNCED, proving
// that the serial connection works in both directions before either proceeds.
UART-BAUD-RATE-SYNC ::= "UART-BAUD-RATE-SYNC"
UART-BAUD-RATE-SYNCED ::= "UART-BAUD-RATE-SYNCED"
UART-TRANSFER-ERROR ::= "UART TRANSFER ERROR"
// Gives the host time to apply the requested rate before the device transmits
// at that rate.
UART-BAUD-RATE-SWITCH-DELAY-MS ::= 50
// Gives USB-UART adapters time to transmit at the old rate before the host
// changes rate. This must be shorter than $UART-BAUD-RATE-SWITCH-DELAY-MS.
UART-HOST-BAUD-RATE-SWITCH-DELAY-MS ::= 5
// The host starts synchronization after the testee has switched to the new rate.
UART-BAUD-RATE-SYNC-DELAY-MS ::= 60
// Bounds the confirmation that both sides can communicate at the new rate.
UART-BAUD-RATE-SYNC-TIMEOUT-MS ::= 1_000
// Retry a synchronization marker that was sent before the testee had switched.
UART-BAUD-RATE-SYNC-ATTEMPTS ::= 3

// The asset that selects mini-jag's control transport.
CONTROL-ASSET ::= "control"

// mini-jag starts at the default console rate, synchronizes with the host,
// then switches to this rate while receiving a test container.
CONSOLE-BAUD-RATE ::= 115_200
CONTROL-BAUD-RATE ::= 921_600

// The device pulls the container image in chunks of this size, requesting
// each one with $CHUNK-REQUEST. The serial transport has no flow control,
// so the device must never have more data in flight than it asked for. Only one
// chunk is outstanding at a time because flash writes can prevent the UART ISR
// from draining the FIFO promptly.
CHUNK-SIZE ::= 1024
CHUNK-REQUEST ::= "READY FOR CHUNK: "
