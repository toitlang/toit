// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import expect show *
import tls
import tls.session
import ...tls-no-net-test as certificates

/** TLS echo server for the ESP32 UART relay; pass a TCP listen port. */
main args/List:
  network := net.open
  listener := network.tcp-listen (int.parse args[0])
  try:
    print "tls-session-host: listening on $(listener.local-address.port)"
    with-timeout --ms=180_000:
      socket := listener.accept
      connection := session.Session.server socket.in socket.out
          --certificate=(tls.Certificate
            certificates.TEST-LOCALHOST-CERT-DIRECTLY-SIGNED
            certificates.TEST-LOCALHOST-KEY-DIRECTLY-SIGNED)
      try:
        total := 0
        while total < 1 + 31 + 256 + 1024:
          bytes := connection.read
          if not bytes: throw "TLS closed before all payloads arrived"
          connection.write bytes
          total += bytes.size
        acknowledgement := #[]
        while acknowledgement.size < 5:
          bytes := connection.read
          if not bytes: throw "RP2350 closed before confirming assertions"
          acknowledgement += bytes
        expect-equals "PASS\n" acknowledgement.to-string
        print "tls-session-host: RP2350 confirmed session export and encrypted echoes"
      finally:
        connection.close
        socket.close
  finally:
    listener.close
    network.close
