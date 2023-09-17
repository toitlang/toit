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

  port := 5353  // MDNS.

  socket := udp.Socket "224.0.0.251" port

  socket.multicast-add-membership
      net.IpAddress.parse "224.0.0.0"
  socket.multicast-loopback = true

  print "Listening"
  while true:
    datagram/net.Datagram := socket.receive
    if datagram.address.port == 5353:
      decoded := dns-tools.decode-packet datagram.data
      print "Received $(decoded.is-response ? "response" : "query") packet from $datagram.address.ip"
      decoded.questions.do: | question |
        type := dns.QTYPE-NAMES.get question.type --if-absent=: "Unknown $question.type"
        print "  Q $question.name $type"
      decoded.resources.do: | resource |
        type := dns.QTYPE-NAMES.get resource.type --if-absent=: "Unknown $resource.type"
        print "  R $resource.name $resource.ttl $type $resource.value"

