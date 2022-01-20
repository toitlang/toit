// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .tcp
import expect show *

main:
  server := TcpServerSocket
  server.listen "localhost" 0

  socket := TcpSocket
  socket.connect "localhost" server.local_address.port

  before := Time.monotonic_us
  e := catch:
    with_timeout --ms=100:
      with_timeout --ms=1_000:
        socket.read
        throw "UNEXPECTED"
  after := Time.monotonic_us
  expect_equals DEADLINE_EXCEEDED_ERROR e
  expect after - before >= 100_000
