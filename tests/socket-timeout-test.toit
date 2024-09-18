// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.tcp

main:
  network := net.open
  server := tcp.TcpServerSocket network
  server.listen "localhost" 0

  socket := tcp.TcpSocket network
  socket.connect "localhost" server.local-address.port

  before := Time.monotonic-us
  e := catch:
    with-timeout --ms=100:
      with-timeout --ms=1_000:
        socket.in.read
        throw "UNEXPECTED"
  after := Time.monotonic-us
  expect-equals DEADLINE-EXCEEDED-ERROR e
  expect after - before >= 100_000
