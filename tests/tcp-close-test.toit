// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .tcp
import monitor show *

main:
  test --timeout=false
  test --timeout=true

// Check we can call close in a finally clause even when our task is
// being cancelled.
test --timeout/bool -> none:
  server-ready := Latch
  connected := Latch

  task::
    server := TcpServerSocket
    server.listen "127.0.0.1" 0
    server-ready.set server.local-address.port
    socket := server.accept

  client := task::
    port := server-ready.get
    socket := TcpSocket
    socket.connect "127.0.0.1" port
    connected.set socket
    if timeout:
      exception := catch:
        with-timeout --ms=500:
          try:
            while true:
              sleep --ms=10
          finally:
            socket.close
      expect exception == "DEADLINE_EXCEEDED"
    else:
      try:
        while true:
          sleep --ms=10
      finally:
        socket.close

  socket := connected.get

  state := socket.state_

  if not timeout:
    client.cancel

  sleep --ms=1000

  // Check we slept long enough for the other task to close.
  expect
      state.resource == null
  
  // Of course the socket is not null, this is just there to ensure we don't GC
  // the socket until now, which might trigger a finalizer-based close instead
  // of the finally-based close we are trying to test.
  expect-not-null socket
