// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.udp
import expect show *

MULTICAST-ADDRESS ::= net.IpAddress.parse "239.1.2.3"
RECEIVE-TIMEOUT-MS ::= 5_000

main:
  network := net.open
  try:
    test-multicast network
  finally:
    network.close

test-multicast network/net.Client:
  // Create a listening socket for multicast using the new API.
  socket := network.udp-open-multicast
      --port=0
      --loopback
      --ttl=1
      --reuse-address
  socket.multicast-add-membership MULTICAST-ADDRESS

  port := socket.local-address.port
  expect port > 0

  // Create a sender socket (normal socket).
  sender := network.udp-open

  msg := "Hello Multicast"
  datagram := udp.Datagram
      msg.to-byte-array
      net.SocketAddress MULTICAST-ADDRESS port

  sender.send datagram

  received := with-timeout --ms=RECEIVE-TIMEOUT-MS: socket.receive
  expect-equals msg received.data.to-string

  sender.close
  socket.close
