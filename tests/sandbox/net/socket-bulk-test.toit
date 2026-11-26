// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: a large upload and download in chunks
  (1 MB echoed through the service while it is still being sent).
*/

import expect show *
import net.sandbox
import .net-util

SIZE ::= 1024 * 1024

main args:
  run-test args --roles={
    "bulk": :: | arguments/Map |
      socket := sandbox.open.tcp-connect "127.0.0.1" arguments["port"]
      data := pattern SIZE
      start := Time.monotonic-us
      task::
        socket.out.write data
        socket.out.close
      received := socket.in.read-all
      elapsed-ms := (Time.monotonic-us - start) / 1000
      expect-equals SIZE received.size
      expect-equals data received
      print "1 MB up and down: $elapsed-ms ms"
      socket.close,
  }:
    server := EchoServer
    port := server.port
    expect-sandbox "bulk" {"port": port}
        --network={"allow": ["127.0.0.1:$port"], "bytes-per-second": 1024 * 1024}
    server.close
