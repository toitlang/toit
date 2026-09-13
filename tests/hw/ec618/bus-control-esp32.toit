// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor
import net
import uart

import .wiring as wiring

/** Forwards the independent UART1 test-control lane to the host coordinator. */
main:
  network := net.open
  port := uart.Port
      --rx=wiring.ESP32-UART1-RX-PIN
      --tx=wiring.ESP32-UART1-TX-PIN
      --baud-rate=115200
  server := network.tcp-listen 18561
  print "BUS-CONTROL $network.address:18561"
  try:
    while socket := server.accept:
      socket.no-delay = true
      done := monitor.Latch
      upstream := task::
        try:
          while data := port.in.read:
            socket.out.write data --flush
        finally:
          done.set true
      try:
        while data := socket.in.read:
          port.out.write data --flush
      finally:
        upstream.cancel
        done.get
        socket.close
  finally:
    server.close
    port.close
    network.close
