// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests UDP multicast functionality:
- Reuse-port option (SO_REUSEPORT on Linux/BSD, SO_REUSEADDR on Windows).
- Multicast send/receive via loopback.
- Multiple receivers on the same port.
- Leave-membership.
- Multicast-interface getter/setter.

Requires multicast routing to be configured on the CI runner
  (see the "Setup multicast route" step in CI).
*/

import expect show *
import net
import net.udp

MULTICAST-ADDRESS ::= net.IpAddress.parse "239.1.2.3"
LOOPBACK-ADDRESS  ::= net.IpAddress.parse "127.0.0.1"

main:
  network := net.open
  try:
    test-reuse-port-binding network
    test-multicast-send-receive network
    test-two-receivers network
    test-leave-membership network
    test-multicast-interface network
  finally:
    network.close

/**
Tests that two multicast sockets can bind to the same port when
  reuse-port is enabled.

Uses an ephemeral port to avoid collisions with parallel test runs.
*/
test-reuse-port-binding network/net.Client:
  // Bind the first socket to an ephemeral port with group join.
  socket1 := network.udp-open-multicast --port=0 --reuse-address --reuse-port --loopback
  socket1.multicast-add-membership MULTICAST-ADDRESS

  port := socket1.local-address.port
  expect port > 0

  // A second socket should be able to bind to the same port.
  socket2 := network.udp-open-multicast --port=port --reuse-address --reuse-port --loopback
  socket2.multicast-add-membership MULTICAST-ADDRESS

  expect-equals port socket2.local-address.port

  socket2.close
  socket1.close

/**
Tests that a multicast message sent to the group is received by a
  member socket with loopback enabled.

The sender uses $net.Client.udp-open-multicast without an address
  (no group join) — it only needs the multicast interface set to
  loopback for sending.
*/
test-multicast-send-receive network/net.Client:
  receiver := network.udp-open-multicast --port=0 --reuse-address --reuse-port --loopback
  receiver.multicast-add-membership MULTICAST-ADDRESS

  port := receiver.local-address.port

  // Sender: no group join, just set the outgoing interface.
  sender := network.udp-open-multicast --if-addr=LOOPBACK-ADDRESS --loopback

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
  receiver1 := network.udp-open-multicast --port=0 --reuse-address --reuse-port --loopback
  receiver1.multicast-add-membership MULTICAST-ADDRESS

  port := receiver1.local-address.port

  receiver2 := network.udp-open-multicast --port=port --reuse-address --reuse-port --loopback
  receiver2.multicast-add-membership MULTICAST-ADDRESS

  // Sender: no group join.
  sender := network.udp-open-multicast --if-addr=LOOPBACK-ADDRESS --loopback

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

/**
Tests that after leaving a multicast group, no more messages are received.

We use a sender to send two messages. The receiver joins, receives the first
  message, then leaves the group. A second message sent after the leave
  should not be received.
*/
test-leave-membership network/net.Client:
  receiver := network.udp-open-multicast --port=0 --reuse-address --loopback
  receiver.multicast-add-membership MULTICAST-ADDRESS

  port := receiver.local-address.port

  sender := network.udp-open-multicast --if-addr=LOOPBACK-ADDRESS --loopback

  // First message should be received.
  msg1 := "Before Leave"
  sender.send
      udp.Datagram msg1.to-byte-array (net.SocketAddress MULTICAST-ADDRESS port)

  received := receiver.receive
  expect-equals msg1 received.data.to-string

  // Leave the group.
  receiver.multicast-leave-membership MULTICAST-ADDRESS

  // Send a second message. It should NOT be received because we left the group.
  // We can't easily test "not received" without a timeout. Instead we send a
  // unicast message to the receiver's local address so we know it gets
  // *something*, and verify it's the unicast message (not the multicast one).
  msg2 := "After Leave"
  sender.send
      udp.Datagram msg2.to-byte-array (net.SocketAddress MULTICAST-ADDRESS port)

  unicast-msg := "Unicast Ping"
  sender.send
      udp.Datagram unicast-msg.to-byte-array (net.SocketAddress LOOPBACK-ADDRESS port)

  received2 := receiver.receive
  // We should get the unicast ping, not the multicast message.
  expect-equals unicast-msg received2.data.to-string

  sender.close
  receiver.close

/**
Tests the multicast-interface getter and setter.

Verifies that after setting the multicast interface to loopback, the
  getter returns the loopback address.
*/
test-multicast-interface network/net.Client:
  socket := network.udp-open-multicast --loopback

  // Default should be 0.0.0.0 (OS picks).
  default-if := socket.multicast-interface
  expect-equals "0.0.0.0" default-if.stringify

  // Set to loopback.
  socket.multicast-interface = LOOPBACK-ADDRESS
  current-if := socket.multicast-interface
  expect-equals "127.0.0.1" current-if.stringify

  socket.close
