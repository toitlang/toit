// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import net
import net.udp
import monitor
import net.modules.dns

main:
  network := net.open
  server := MdnsServer network
  server.run

class MdnsServer:
  network := ?
  socket := ?
  my-ip/net.IpAddress := ?
  cache/Map := {:}

  static PORT ::= 8080  // MDNS would be 5353.
  static IP ::= net.IpAddress.parse "224.0.0.80"  // MDNS would be 224.0.0.251.
  static ADDR ::= net.SocketAddress IP PORT

  constructor .network:
    socket = network.udp_open --port=PORT
    socket.multicast-add-membership
        net.IpAddress.parse "224.0.0.0"
    socket.multicast-loopback = true
    socket2 := network.udp_open --port=PORT
    THE_INTERNET ::= net.SocketAddress (net.IpAddress.parse "8.8.8.8") 53
    socket2.connect THE_INTERNET
    my-ip = socket2.local-address.ip
    socket2.close
    // Do not connect the socket to a particular address!

  run -> none:
    try:
      while true:
        packet := udp.Datagram "testing".to-byte-array ADDR
        socket.send packet
        expect-equals "testing" socket.read.to-string
        print "OK"
        sleep --ms=1000
    finally:
      socket.close
