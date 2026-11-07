// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import log
import net
import uart

// NONOS AT mistakes a literal three-plus payload for a send abort. Check that
// the adapter surfaces its completed error and retains the synchronized session.
// This is a firmware-defect regression, not a binary-transparency success test.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    tcp := network.tcp-connect "200.200.200.1" 4242
    udp := network.udp-open
    udp.connect (net.SocketAddress (net.IpAddress.parse "200.200.200.1") 4242)
    [false, true].do: | datagram/bool |
      with-timeout --ms=2000:
        error := catch:
          if datagram: udp.write "+++"
          else: tcp.out.write "+++"
        // The prompt's optional trailing space can become an empty response
        // list. Only the completed error code matters here.
        expect (error is string and error.starts-with "SEND Canceled ")
      expect (not network.is-closed)
      with-timeout --ms=5000:
        tcp.out.write "after cancel"
        expect-equals "after cancel".to-byte-array (tcp.in.read-bytes 12)
        expect-equals 4 (udp.write "next")
        expect-equals "next".to-byte-array udp.receive.data
      print "ESP8285 canceled $(datagram ? "UDP" : "TCP") send: PASS"
    tcp.close
    udp.close
    print "RP2040 ESP8285 send canceled handling: PASS"
  finally:
    network.close
    port.close
