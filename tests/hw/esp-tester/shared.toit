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
