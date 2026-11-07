// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import log
import net
import system
import uart

main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    print "ESP8285 network address: $network.address"
    address := net.SocketAddress (net.IpAddress.parse "200.200.200.1") 4242
    tcp := network.tcp-connect address
    try:
      expect (tcp.local-address.port > 0)
      print "ESP8285 TCP local=$tcp.local-address peer=$tcp.peer-address"
      3.repeat: | round/int |
        payload := ByteArray 3001: (it * 37 + round * 13) & 0xff
        with-timeout --ms=10_000:
          tcp.out.write payload
          system.process-stats --gc
          expect-equals payload (tcp.in.read-bytes payload.size)
      print "ESP8285 network TCP: PASS"
    finally:
      tcp.close
    [null, 41000].do: | local-port |
      udp := network.udp-open --port=local-port
      try:
        expect (udp.local-address.port > 0)
        udp.connect address
        print "ESP8285 UDP local=$udp.local-address"
        8.repeat: | round/int |
          payload := ByteArray 512: (it * 41 + round * 17) & 0xff
          with-timeout --ms=5000:
            expect-equals payload.size (udp.write payload)
            system.process-stats --gc
            datagram := udp.receive
            expect-equals payload datagram.data
            expect-equals address.ip datagram.address.ip
            expect-equals address.port datagram.address.port
        print "ESP8285 network UDP: PASS"
      finally:
        udp.close
  finally:
    network.close
    port.close
  print "RP2040 ESP8285 network adapter: PASS"
