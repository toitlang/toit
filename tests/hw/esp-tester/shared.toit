// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

MINI-JAG-LISTENING ::= "MINI-JAG LISTENING"
RUN-TEST ::= "RUN TEST"
INSTALLED-CONTAINER ::= "INSTALLED CONTAINER"
RUNNING-CONTAINER ::= "RUNNING INSTALLED CONTAINER"
// A test prints this marker (followed by a payload) to ask the tester to
// write the payload back over the serial connection. Used by tests that
// exercise console UART input.
UART-INPUT-REQUEST ::= "UART-INPUT-REQUEST: "
// A test prints this marker followed by a baud rate to ask the tester to
// acknowledge at the current rate and then switch the serial connection.
UART-BAUD-RATE-REQUEST ::= "UART-BAUD-RATE-REQUEST: "
UART-BAUD-RATE-ACK ::= "UART-BAUD-RATE-ACK"
// Gives the host time to apply the requested rate before the device transmits
// at that rate.
UART-BAUD-RATE-SWITCH-DELAY-MS ::= 10

// The asset that selects mini-jag's control transport.
CONTROL-ASSET ::= "control"

// mini-jag starts at the default console rate, synchronizes with the host,
// then switches to this rate while receiving a test container.
CONSOLE-BAUD-RATE ::= 115_200
CONTROL-BAUD-RATE ::= 921_600

// The device pulls the container image in chunks of this size, requesting
// each one with $CHUNK-REQUEST. The serial transport has no flow control,
// so the device must never have more data in flight than it asked for. It
// keeps up to two chunks in flight (so the wire stays busy while a chunk
// is written to flash), which means both must fit in the console UART's
// 4096-byte receive buffer.
CHUNK-SIZE ::= 1920
CHUNK-REQUEST ::= "READY FOR CHUNK"
