// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *
import tls.session
import uart
import .tls-transport as transport
import .wiring as wiring

/**
Exercises TLS session export and encrypted records over the paired UART.

Start the host server and ESP32 relay first. The UART is the TLS transport, so this
  test needs no RP2350 network stack. Certificate validation is intentionally
  disabled: this tests key export and record processing, not peer identity.
*/
main:
  port := uart.Port
      --tx=wiring.RP2350-UART-TX-PIN
      --rx=wiring.RP2350-UART-RX-PIN
      --baud-rate=115_200
  connection := session.Session.client (transport.Reader port) (transport.Writer port)
      --skip-certificate-validation
  try:
    with-timeout --ms=60_000:
      port.out.write "TLS\n"
      port.out.flush
      connection.handshake
      expect-equals session.SESSION-MODE-TOIT connection.mode
      state := tison.decode connection.session-state
      expect-equals 4 state.size
      expect-equals 48 state[2].size
      [1, 31, 256, 1024].do: | size/int |
        payload := ByteArray size: (it * 37 + size) & 0xff
        connection.write payload
        received := #[]
        while received.size < size:
          bytes := connection.read
          if not bytes: throw "TLS closed before echo completed"
          received += bytes
        expect-equals payload received
      connection.write "PASS\n"
      print "tls-session-rp2350: exported session and encrypted echoes passed"
  finally:
    connection.close
    port.close
