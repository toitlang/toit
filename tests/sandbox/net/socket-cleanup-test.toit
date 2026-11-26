// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: the connections of a sandbox are closed
  when it is stopped, when it ends without closing them, and when it ends
  with an uncaught exception; its connections stop counting against the
  limit of all sandboxes.
*/

import expect show *
import net.sandbox
import .net-util

main args:
  run-test args --roles={
    "hold": :: | arguments/Map |
      network := sandbox.open
      sockets := List arguments["count"]: network.tcp-connect "127.0.0.1" arguments["port"]
      if arguments["end"] == "exit": exit 0
      if arguments["end"] == "throw": throw "BOOM"
      while true: sleep --ms=100,
  }:
    server := EchoServer
    port := server.port
    network := {"allow": ["127.0.0.1:$port"], "connections": 4}

    // Stopped by its owner.
    holder := start-sandbox "hold" {"port": port, "count": 4, "end": "sleep"} --network=network
    server.wait-open 4
    holder.stop
    server.wait-open 0

    // Ends without closing them.
    expect-sandbox "hold" {"port": port, "count": 3, "end": "exit"} --network=network
    server.wait-open 0

    // Ends with an uncaught exception.
    expect-equals 1
        run-sandbox "hold" {"port": port, "count": 2, "end": "throw"} --network=network
    server.wait-open 0

    // Two sandboxes at the same time: stopping one leaves the other's
    // connections alone.
    a := start-sandbox "hold" {"port": port, "count": 4, "end": "sleep"} --network=network
    server.wait-open 4
    b := start-sandbox "hold" {"port": port, "count": 2, "end": "sleep"} --network=network
    server.wait-open 6
    a.stop
    server.wait-open 2
    b.stop
    server.wait-open 0
    expect-equals 15 server.accepted
    server.close
