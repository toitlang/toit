// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import cellular.modules.espressif.esp8285 show Esp8285
import expect show *
import log
import uart

SIZE ::= 602_116

main:
  port := uart.Port --tx=0 --rx=1 --baud-rate=115_200 --large-buffers
  try:
    [0, 300, 600].do: | pause-ms/int |
      network := Esp8285 port.in port.out --logger=(log.default.with-level log.INFO-LEVEL)
      try:
        network.connect "toit-rp2040-test" "pico-bringup-test"
        receive network port pause-ms
      finally:
        network.close
    print "RP2040 ESP8285 paced TCP: PASS"
  finally:
    port.close

receive network/Esp8285 port/uart.Port pause-ms/int:
  port-number := {0: 4243, 300: 4246, 600: 4247}[pause-ms]
  socket := network.tcp-connect "200.200.200.1" port-number
  total := 0
  next-progress := 65536
  started := Time.monotonic-us
  last-progress := started
  initial-errors := port.errors
  observer := task::
    while true:
      sleep --ms=5000
      idle-ms := (Time.monotonic-us - last-progress) / 1000
      if idle-ms >= 10_000:
        print "ESP8285 paced TCP: idle-ms=$idle-ms bytes=$total pause-ms=$pause-ms uart-errors=$(port.errors)"
  try:
    print "ESP8285 paced TCP: start pause-ms=$pause-ms uart-errors=$initial-errors"
    with-timeout --ms=180_000:
      while bytes := socket.in.read:
        expect (total + bytes.size <= SIZE)
        expect-equals (ByteArray bytes.size: ((total + it) * 31 + 19) & 0xff) bytes
        total += bytes.size
        last-progress = Time.monotonic-us
        if total >= next-progress:
          print "ESP8285 paced TCP: bytes=$total pause-ms=$pause-ms"
          next-progress += 65536
      expect-equals SIZE total
    expect-equals 0 port.errors
    elapsed-ms := (Time.monotonic-us - started) / 1000
    print "ESP8285 paced TCP: PASS bytes=$total pause-ms=$pause-ms elapsed-ms=$elapsed-ms uart-errors=$(port.errors)"
  finally:
    observer.cancel
    print "ESP8285 paced TCP: final bytes=$total pause-ms=$pause-ms uart-errors=$(port.errors)"
    socket.close
