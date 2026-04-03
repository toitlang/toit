// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the UDP reuse-port option works on all platforms.

On Linux and BSD this maps to SO_REUSEPORT.
On Windows this maps to SO_REUSEADDR, which already provides port-reuse
  semantics.
*/

import expect show *
import monitor
import net
import net.udp
import net.modules.udp as impl

MULTICAST-ADDRESS ::= net.IpAddress.parse "239.1.2.3"

main:
  network := net.open
  try:
    test-multicast-reuse-port network
    test-multicast-send-receive-with-reuse-port network
  finally:
    network.close

/**
Tests that two multicast sockets can bind to the same port when
  reuse-port is enabled.
*/
test-multicast-reuse-port network/net.Client:
  port := 15432

  socket1 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  // A second socket should be able to bind to the same port.
  socket2 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  addr1 := socket1.local-address
  addr2 := socket2.local-address
  expect-equals port addr1.port
  expect-equals port addr2.port

  socket2.close
  socket1.close

/**
Tests that a multicast socket created with reuse-port can send and
  receive data through loopback.
*/
test-multicast-send-receive-with-reuse-port network/net.Client:
  port := 15433

  socket := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  sender := network.udp-open

  msg := "reuse-port-test"
  datagram := udp.Datagram
      msg.to-byte-array
      net.SocketAddress MULTICAST-ADDRESS port

  sender.send datagram

  received := socket.receive
  expect-equals msg received.data.to-string

  sender.close
  socket.close
