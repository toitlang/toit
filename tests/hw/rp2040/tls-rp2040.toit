// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import encoding.base64
import expect show *
import io
import io.stdio
import rp2040
import system
import tls
import tls.session
import ...tls-no-net-test as certificates

// TLS records travel over USB. No modem, network stack or header pins are used.
main:
  expect-equals 1970 Time.now.utc.year
  ticks := 0
  collector := task::
    while true:
      system.process-stats --gc
      ticks++
      sleep --ms=10
  try:
    ["unset", "valid", "wrong-host", "untrusted", "future", "expired", "valid-again"].do: | mode/string |
      if mode != "unset":
        year := mode == "future" ? 2020 : (mode == "expired" ? 2050 : 2026)
        before := Time.monotonic-us
        rp2040.set-real-time-clock (Time.utc --year=year --month=11 --day=1)
        expect-equals year Time.now.utc.year
        expect (Time.monotonic-us >= before)
      print "tls-rp2040: READY $mode"
      connection := session.Session.client Reader Writer
          --server-name=(mode == "wrong-host" ? "wrong.example" : "localhost")
          --root-certificates=(mode == "untrusted" ? [] : [certificates.TEST-ROOT-CERT])
          --certificate=(tls.Certificate certificates.TEST-CLIENT-CERT-DIRECTLY-SIGNED
              certificates.TEST-CLIENT-KEY-DIRECTLY-SIGNED)
      try:
        with-timeout --ms=60_000:
          error := catch: connection.handshake
          if mode != "valid" and mode != "valid-again":
            // Require an authentication failure, not a transport error/timeout.
            print "tls-rp2040: rejection $mode: $error"
            expect (error is string)
            if mode == "wrong-host":
              expect (error.contains "CN_MISMATCH")
            else if mode == "unset" or mode == "future":
              expect (error.contains "FUTURE")
            else if mode == "expired":
              expect (error.contains "EXPIRED")
            else:
              expect ((error.contains "NOT_TRUSTED") or (error.contains "No root certificate provided"))
            print "tls-rp2040: PASS $mode rejected"
          else:
            if error: throw error
            expect-equals session.SESSION-MODE-TOIT connection.mode
            [1, 31, 256, 1024, 2049].do: | size/int |
              payload := ByteArray size: (it * 37 + size) & 0xff
              connection.write payload
              received := #[]
              while received.size < size:
                bytes := connection.read
                if not bytes: throw "TLS closed before echo completed"
                received += bytes
              expect-equals payload received
            print "tls-rp2040: PASS authenticated TLS and encrypted echoes"
      finally:
        connection.close
    expect (ticks > 0)
    print "tls-rp2040: PASS"
  finally:
    collector.cancel

class Reader extends io.CloseableReader:
  read_ -> ByteArray?:
    line := (stdio.stdin.read-bytes-up-to '\n').to-string
    if not line.starts-with "TLS ": throw "Invalid TLS test frame"
    return base64.decode line[4..]
  close_ -> none:

class Writer extends io.CloseableWriter:
  try-write_ data/io.Data from/int to/int -> int:
    if from == to: return 0
    // Keep frames below the native stdin buffer size in both directions.
    end := min to (from + 512)
    bytes := ByteArray (end - from)
    data.write-to-byte-array bytes --at=0 from end
    print "TLS $(base64.encode bytes)"
    return end - from
  close_ -> none:
