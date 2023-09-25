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

  socket.multicast-loopback = true
  socket.multicast-ttl = 3
  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.251"
  socket.multicast-loopback = true

  socket.connect
    net.SocketAddress
      net.IpAddress.parse "224.0.0.251"
      port

  task::
    print "Waiting for data"
    expect-equals "testing" socket.read.to-string
    print "Got it"
    socket.close

  sleep --ms=2000

  socket.write "testing"
  print "Wrote"
