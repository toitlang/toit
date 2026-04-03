// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the UDP reuse-port option works on all platforms.

On Linux and BSD this maps to SO_REUSEPORT.
On Windows this maps to SO_REUSEADDR, which already provides port-reuse
  semantics.

Requires multicast routing to be configured on the CI runner.
*/

import expect show *
import net
import net.udp
import net.modules.udp as impl

MULTICAST-ADDRESS ::= net.IpAddress.parse "239.1.2.3"

main:
  network := net.open
  try:
    test-reuse-port-binding network
    test-multicast-send-receive network
    test-two-receivers network
  finally:
    network.close

/**
Tests that two multicast sockets can bind to the same port when
  reuse-port is enabled.
*/
test-reuse-port-binding network/net.Client:
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
Tests that a multicast message sent to the group is received by a
  member socket with loopback enabled.
*/
test-multicast-send-receive network/net.Client:
  port := 15433

  receiver := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  sender := network.udp-open

  msg := "Hello Multicast"
  datagram := udp.Datagram
      msg.to-byte-array
      net.SocketAddress MULTICAST-ADDRESS port

  sender.send datagram

  received := receiver.receive
  expect-equals msg received.data.to-string

  sender.close
  receiver.close

/**
Tests that two sockets bound to the same multicast port (via
  reuse-port) can both receive data sent to the group.
*/
test-two-receivers network/net.Client:
  port := 15434

  receiver1 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  receiver2 := impl.Socket.multicast network
      MULTICAST-ADDRESS
      port
      --reuse-address
      --reuse-port
      --loopback

  sender := network.udp-open

  msg := "Reuse Port Test"
  datagram := udp.Datagram
      msg.to-byte-array
      net.SocketAddress MULTICAST-ADDRESS port

  sender.send datagram

  // Both receivers should get the multicast message.
  received1 := receiver1.receive
  expect-equals msg received1.data.to-string

  received2 := receiver2.receive
  expect-equals msg received2.data.to-string

  sender.close
  receiver2.close
  receiver1.close
