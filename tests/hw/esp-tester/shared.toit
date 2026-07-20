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
UART-TRANSFER-ERROR ::= "UART TRANSFER ERROR"
// Gives the host time to apply the requested rate before the device transmits
// at that rate.
UART-BAUD-RATE-SWITCH-DELAY-MS ::= 10
// Gives USB-UART adapters time to transmit at the old rate before the host
// changes rate. This must be shorter than $UART-BAUD-RATE-SWITCH-DELAY-MS.
UART-HOST-BAUD-RATE-SWITCH-DELAY-MS ::= 5

// The asset that selects mini-jag's control transport.
CONTROL-ASSET ::= "control"

// mini-jag starts at the default console rate, synchronizes with the host,
// then switches to this rate while receiving a test container.
CONSOLE-BAUD-RATE ::= 115_200
CONTROL-BAUD-RATE ::= 921_600

// The device pulls the container image in chunks of this size, requesting
// each one with $CHUNK-REQUEST. The serial transport has no flow control,
// so the device must never have more data in flight than it asked for. It
// keeps two requested chunks outstanding so the wire stays busy while a chunk
// is written to flash. Together they use half of the 4096-byte receive buffer,
// leaving the other half as headroom.
CHUNK-SIZE ::= 1024
CHUNK-REQUEST ::= "READY FOR CHUNK"
