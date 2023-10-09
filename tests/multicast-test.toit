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

my-ip:
  network := net.open
  socket2 := network.udp_open
  THE_INTERNET ::= net.SocketAddress (net.IpAddress.parse "8.8.8.8") 53
  socket2.connect THE_INTERNET
  my-ip := socket2.local-address.ip
  print "My IP is $my-ip"
  return my-ip

multicast-test:
  times := 10

  PORT := 5353  // MDNS.

  my-ip

  socket := udp.Socket "224.0.0.251" PORT
  socket2 := udp.Socket "224.0.0.251" PORT

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  socket2.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
      --interface-address=(net.IpAddress.parse "10.0.0.42")
  socket.multicast-ttl = 42

  expect-equals 42
      socket.multicast-ttl

  dest := net.SocketAddress (net.IpAddress.parse "224.0.0.251") PORT
  packet := net.Datagram "testing".to-byte-array dest

  for i := 0; i < times; i++:
    socket.send packet
    expect-equals "testing" socket2.read.to-string
    print "OK"
  socket.close
  socket2.close
