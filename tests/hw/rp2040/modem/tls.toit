// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import log
import rp2040
import system
import tls
import uart
import ....tls-no-net-test as certificates

// The modem carries TCP bytes; all TLS and certificate validation run on Pico.
main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
  ticks := 0
  collector := task::
    while true:
      system.process-stats --gc
      ticks++
      sleep --ms=10
  try:
    network.connect "toit-rp2040-test" "pico-bringup-test"
    ["valid", "wrong-host", "untrusted", "expired", "valid-again"].do: | mode/string |
      rp2040.set-real-time-clock (Time.utc --year=(mode == "expired" ? 2050 : 2026) --month=11 --day=1)
      socket := network.tcp-connect "200.200.200.1" 4244
      secure := tls.Socket.client socket
          --server-name=(mode == "wrong-host" ? "wrong.example" : "localhost")
          --root-certificates=(mode == "untrusted" ? [] : [certificates.TEST-ROOT-CERT])
      try:
        with-timeout --ms=60_000:
          started := Time.monotonic-us
          error := catch: secure.handshake
          if mode == "valid" or mode == "valid-again":
            if error:
              print "ESP8285 TLS $mode handshake failed: $error"
              throw error
            print "ESP8285 TLS $mode handshake: $((Time.monotonic-us - started) / 1000) ms"
            [1, 31, 256, 1024, 2049, 8193].do: | size/int |
              payload := ByteArray size: (it * 37 + size) & 0xff
              secure.out.write payload
              expect-equals payload (secure.in.read-bytes size)
            print "ESP8285 TLS $mode: authenticated, 11554 encrypted bytes PASS"
          else:
            expect (error is string)
            if mode == "wrong-host": expect (error.contains "CN_MISMATCH")
            else if mode == "expired": expect (error.contains "EXPIRED")
            else: expect ((error.contains "NOT_TRUSTED") or (error.contains "No root certificate provided"))
            print "ESP8285 TLS $mode: certificate rejected PASS"
      finally:
        secure.close
      expect (not network.is-closed)
    expect (ticks > 0)
    print "RP2040 ESP8285 TLS: PASS"
  finally:
    collector.cancel
    network.close
    port.close
