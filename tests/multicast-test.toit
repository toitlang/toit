// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show BIG-ENDIAN
import bytes show Buffer
import expect show *

import .udp as udp
import net
import net.udp as net
import .dns as dns
import net.modules.dns-tools

main:
  multicast-test

multicast-test:
  times := 10

  port := 8080  // Not the MDNS port.

  socket := udp.Socket "224.0.0.251" port

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  socket.multicast-loopback = true

  task --background::
    sleep --ms=200
    socket.send
        net.Datagram
            "Hello, World!".to-byte-array
            net.SocketAddress (net.IpAddress.parse "224.0.0.251") port

  print "Listening"
  while true:
    datagram/net.Datagram := socket.receive
    if datagram.address.port == port:
      decoded := datagram.data.to-string
      expect-equals "Hello, World!" decoded
      print "OK"
      return
    else:
      print "datagram.address=$datagram.address, datagram.data=$datagram.data"
