// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// https://github.com/toitware/toit/issues/3

import ..tcp

expect name [code]:
  expect_equals
    name
    catch code

main:
  // Port 47 is reserved/unassigned.
  socket := TcpSocket
  expect "Connection refused": socket.connect "localhost" 47
