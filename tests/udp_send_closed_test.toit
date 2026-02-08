// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license.

import net
import net.udp
import expect show *

main:
  test-send-closed

test-send-closed:
  network := net.open
  socket := network.udp-open
  
  // Start a task that closes the socket while we are trying to send.
  task::
    sleep --ms=5
    socket.close

  // Try to send until we get an error or completion.
  // Launch multiple tasks to ensure we hit the race where one is blocked.
  10.repeat:
    task::
      1000.repeat:
        e := catch:
          socket.send (udp.Datagram (ByteArray 3) (net.SocketAddress (net.IpAddress.parse "127.0.0.1") 1234))
        if e:
          if e != "NOT_CONNECTED": throw e
          // If we caught NOT_CONNECTED, we are good this iteration.

  sleep --ms=100
  print "Test finished without crash"
