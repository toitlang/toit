// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import net
import uart

import .wiring as wiring

/** Forwards the independent UART1 test-control lane to the host coordinator. */
main:
  // Add the helper's internal pulls for the replacement I2C1 fixture's
  // wiring. Both pins stay inputs, including while SPI owns these nets.
  scl-pull := gpio.Pin wiring.ESP32-I2C1-SCL-PIN --input --pull-up
  sda-pull := gpio.Pin wiring.ESP32-I2C1-SDA-PIN --input --pull-up
  network := net.open
  port := uart.Port
      --rx=wiring.ESP32-UART1-RX-PIN
      --tx=wiring.ESP32-UART1-TX-PIN
      --baud-rate=115200
  server := network.tcp-listen 18561
  print "BUS-CONTROL $network.address:18561"
  try:
    while true:
      socket := server.accept
      if not socket: continue
      socket.no-delay = true
      done := monitor.Latch
      upstream := task::
        try:
          while data := port.in.read:
            socket.out.write data --flush
        finally:
          critical-do: done.set true
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
    scl-pull.close
    sda-pull.close
