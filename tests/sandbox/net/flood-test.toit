// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A sandbox that floods the sandbox network services (two busy echo
  connections, a stream of refused connection attempts and of HTTP requests)
  doesn't starve a trusted client of the trusted network service, which is
  in the same system process: no call of the sandbox waits for the network
  in an RPC task of the system process.
*/

import expect show *
import net
import net.sandbox
import net.sandbox-http
import .net-util

main args:
  run-test args --roles={
    "flood": :: | arguments/Map |
      port := arguments["port"]
      http-port := arguments["http-port"]
      network := sandbox.open
      2.repeat:
        socket := network.tcp-connect "127.0.0.1" port
        task::
          data := pattern 4096
          while true:
            socket.out.write data
            socket.in.read
      task::
        while true:
          catch: (network.tcp-connect "127.0.0.1" port).close
          catch: network.tcp-connect "127.0.0.1" port + 1
      task::
        client := sandbox-http.open
        while true:
          catch:
            response := client.get "http://127.0.0.1:$http-port/small"
            response.body.read-all
            response.close
      while true: sleep --ms=100,
  }:
    server := EchoServer
    http-server := HttpServer
    flood := start-sandbox "flood" {"port": server.port, "http-port": http-server.port}
        --network={
          "allow": ["127.0.0.1:$server.port", "127.0.0.1:$http-server.port"],
          "connections": 4,
          "attempts-per-minute": 600,
          "bytes-per-second": 1024 * 1024,
          "bytes-per-day": 1 << 30,
        }
    // Let the flood start.
    server.wait-open 2
    sleep --ms=500
    worst := 0
    total := 0
    rounds := 30
    rounds.repeat:
      start := Time.monotonic-us
      network := net.open
      socket := network.tcp-connect "127.0.0.1" server.port
      socket.out.write "trusted"
      expect-equals "trusted" socket.in.read.to-string
      socket.close
      network.close
      elapsed := Time.monotonic-us - start
      worst = max worst elapsed
      total += elapsed
      sleep --ms=20
    print "trusted network round trip during the flood: average $(total / rounds / 1000) ms, worst $(worst / 1000) ms"
    print "http requests served: $http-server.requests"
    expect worst < 1_000_000
    flood.stop
    server.wait-open 0
    server.close
    http-server.close
