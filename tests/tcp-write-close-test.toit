// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show *
import net
import net.modules.tcp

// Data written just before a close must reach the peer, even when the peer
// only starts reading after the close has happened. On Windows a close used
// to be abortive, which sent an RST and discarded the payload.

HEADER ::= "4096\n".to-byte-array
PAYLOAD ::= ByteArray 4096: it & 0xff

main:
  network := net.open
  port := Latch
  closed := Latch

  task::
    server := tcp.TcpServerSocket network
    server.listen "127.0.0.1" 0
    port.set server.local-address.port
    socket := server.accept
    // Two separate writes, then an immediate close.
    socket.out.write HEADER
    socket.out.write PAYLOAD
    socket.close
    server.close
    closed.set true

  socket := tcp.TcpSocket network
  socket.connect "127.0.0.1" port.get
  // Don't read anything until the peer has written and closed. The data is
  // then sitting in our receive buffer, which is what an abortive close on
  // the other side throws away.
  closed.get
  sleep --ms=100
  received := socket.in.read-all
  socket.close
  expect-equals HEADER.size + PAYLOAD.size received.size
  expect-equals HEADER + PAYLOAD received
