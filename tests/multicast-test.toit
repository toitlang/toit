// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .udp as udp
import net
import net.udp as net
import monitor
import .dns as dns

BROADCAST-ADDRESS ::= net.IpAddress.parse "255.255.255.255"

main:
  multicast-test

multicast-test:
  times := 10

  PORT := 5353  // MDNS.

  socket := udp.Socket "224.0.0.251" PORT

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  socket.multicast-loopback = true
  socket.multicast-ttl = 42

  expect
      socket.multicast-loopback
  expect-equals 42
      socket.multicast-ttl

  dest := net.SocketAddress (net.IpAddress.parse "224.0.0.251") PORT
  packet := net.Datagram "testing".to-byte-array dest

  for i := 0; i < times; i++:
    socket.send packet
    expect-equals "testing" socket.read.to-string
    print "OK"
  socket.close
