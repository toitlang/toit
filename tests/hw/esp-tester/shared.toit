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
