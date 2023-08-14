// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp
import expect show *

main:
  server := TcpServerSocket
  server.listen "localhost" 0

  socket := TcpSocket
  socket.connect "localhost" server.local-address.port

  before := Time.monotonic-us
  e := catch:
    with-timeout --ms=100:
      with-timeout --ms=1_000:
        socket.read
        throw "UNEXPECTED"
  after := Time.monotonic-us
  expect-equals DEADLINE-EXCEEDED-ERROR e
  expect after - before >= 100_000
