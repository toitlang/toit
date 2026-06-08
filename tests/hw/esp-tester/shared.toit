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
// The ESP32 mini-jag uses TCP/Wi-Fi for its control channel and the serial
// line only for console output. The EC618 has neither Wi-Fi nor a host reset
// line in our rig, so the whole control channel moves onto the device's print
// UART. Protocol bytes are therefore interleaved with the device's own
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
CMD-FW-BEGIN   ::= 'F'  // <size:4 LE>                -> ACK-OK / ACK-ERROR.
CMD-FW-WRITE   ::= 'W'  // <len:4 BE><bytes>          -> ACK-READY then ACK-OK / ACK-ERROR.
CMD-FW-COMMIT  ::= 'M'  // <sha256:32>                -> ACK-OK / ACK-ERROR.
CMD-FW-UPGRADE ::= 'U'  // -> ACK-OK, then the device reboots into the trial slot.
CMD-TRIAL      ::= 'T'  // -> ACK-TRIAL-YES / ACK-TRIAL-NO.
CMD-VALIDATE   ::= 'V'  // -> ACK-OK.
CMD-ROLLBACK   ::= 'Z'  // -> ACK-OK, then the device reboots back to the good slot.

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

// Name of the long-running keep-alive container the EC618 envelope installs
// alongside the agent. It keeps the VM scheduling (never EXIT_DONE / deep sleep,
// which would gate the watchdog and brick a no-remote-reset rig) even if the
// agent crashes. The host's envelope build adds it under this name; the agent
// spares it in clear-containers and skips it in run-installed (it is not a test).
SLEEPER-NAME ::= "sleeper"
