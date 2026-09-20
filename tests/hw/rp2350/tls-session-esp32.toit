// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import net
import uart
import .wiring as wiring

/** Relays the RP2350 UART to tls-session-host.toit on the given host and port. */
main args/List:
  if args.size != 2: throw "Expected host and TCP port"
  network := net.open
  port := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
      --large-buffers
  socket := network.tcp-connect args[0] (int.parse args[1])
  relay/Task? := null
  try:
    run := gpio.Pin wiring.ESP32-RUN-PIN --output --open-drain --value=0
    try:
      sleep --ms=100
      run.set 1
    finally:
      run.close
    with-timeout --ms=120_000:
      expect-equals 'T' port.in.read-byte
      expect-equals 'L' port.in.read-byte
      expect-equals 'S' port.in.read-byte
      expect-equals '\n' port.in.read-byte
      relay = task::
        while bytes := port.in.read: socket.out.write bytes
      while bytes := socket.in.read: port.out.write bytes
      port.out.flush
      print "tls-session-esp32: relay completed"
  finally:
    if relay: relay.cancel
    socket.close
    port.close
    network.close
