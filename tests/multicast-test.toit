// Copyright (C) 2018 Toitware ApS.
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

  port := 5353  // MDNS.

  socket := udp.Socket "224.0.0.251" port

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  //socket.multicast-loopback = false

  socket.connect
    net.SocketAddress
      net.IpAddress.parse "224.0.0.251"
      port

  for i := 0; i < times; i++:
    socket.write "testing"
    expect-equals "testing" socket.read.to-string
  socket.close
