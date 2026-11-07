// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import log
import monitor
import net
import system
import uart

main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  helper := net.IpAddress.parse "200.200.200.1"
  try:
    3.repeat: | cycle/int |
      network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
      try:
        network.connect "toit-rp2040-test" "pico-bringup-test" --dns-server=helper
        expect-equals [helper] (network.resolve "echo.rp2040.test")
        error := catch: network.resolve "absent.rp2040.test"
        expect (error != null)
        expect (not network.is-closed)
        expect-equals [helper] (network.resolve "burst.rp2040.test")
        print "ESP8285 DNS cycle=$cycle: PASS"
        test-traffic network helper cycle
      finally:
        network.close
      system.process-stats --gc
    print "RP2040 ESP8285 network stress: PASS"
  finally:
    port.close

test-traffic network/Esp8285 helper/net.IpAddress cycle/int:
  tcp := network.tcp-connect "burst.rp2040.test" 4243
  udp := network.udp-open
  done := monitor.Latch
  worker/Task? := null
  try:
    udp.connect (net.SocketAddress helper 4242)
    worker = task::
      error := catch:
        32.repeat: | round/int |
          payload := ByteArray 257: (it * 41 + round * 17 + cycle) & 0xff
          with-timeout --ms=10_000:
            expect-equals payload.size (udp.write payload)
            response := udp.receive
            expect-equals payload response.data
            expect-equals helper response.address.ip
            expect-equals 4242 response.address.port
      if error: done.set error --exception
      else: done.set true
    // The helper sends far more than the modem's receive window. During this
    // pause TCP data must remain in the modem/peer, while UDP and commands run.
    sleep --ms=1000
    total := 0
    reads := 0
    with-timeout --ms=60_000:
      while data := tcp.in.read:
        expect (total + data.size <= 65_537)
        expect-equals (ByteArray data.size: ((total + it) * 31 + 19) & 0xff) data
        total += data.size
        reads++
        if reads % 8 == 0: system.process-stats --gc
      expect-equals 65_537 total
      expect done.get
    print "ESP8285 traffic cycle=$cycle TCP=$total UDP=32x257: PASS"
  finally:
    if worker: worker.cancel
    udp.close
    tcp.close
