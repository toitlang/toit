// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The provider's one-word network policies and its limits per container:
- "all": every destination (loopback included), no limits;
- "public": every public address, nothing internal;
- a list of rules: these destinations, no limits;
- one policy for all sandboxes, its limits kept per container: two
  sandboxes at the same time each get their own connection limit (the
  provider tells them apart by the group id the VM gives it).
*/

import expect show *
import net.sandbox
import net.sandbox-http
import .net-util

main args:
  run-test args --roles={
    "all": :: | arguments/Map |
      network := sandbox.open
      // More attempts than the default limit, loopback without a rule.
      40.repeat:
        socket := network.tcp-connect "127.0.0.1" arguments["port"]
        socket.close
      socket := network.tcp-connect "localhost" arguments["port"]
      socket.out.write "all"
      expect-equals "all" socket.in.read.to-string
      socket.close
      // Variant H is available as well.
      response := sandbox-http.open.get "http://127.0.0.1:$arguments["http-port"]/small"
      expect-equals "hello" response.body.read-all.to-string,

    "public": :: | arguments/Map |
      network := sandbox.open
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" arguments["port"])
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "192.168.1.1" 80)
      expect-equals "CONNECT_FAILED" (catch: network.tcp-connect "localhost" arguments["port"]),

    "unlimited": :: | arguments/Map |
      network := sandbox.open
      30.repeat: (network.tcp-connect "127.0.0.1" arguments["port"]).close
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      start := Time.monotonic-us
      task::
        socket.out.write (pattern 200_000)
        socket.out.close
      expect-equals (pattern 200_000) socket.in.read-all
      // At the default 16 KB/s this would take 25 s.
      expect (Time.monotonic-us - start) < 10_000_000
      socket.close
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" arguments["other-port"]),

    "own-limit": :: | arguments/Map |
      network := sandbox.open
      // Both sandboxes hold their one connection at the same time.
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: network.tcp-connect "127.0.0.1" arguments["port"])
      sleep --ms=500
      socket.close,
  }:
    server := EchoServer
    other := EchoServer
    http-server := HttpServer
    port := server.port
    // The one short argument a sandbox needs: --services="all".
    expect-sandbox "all" {"port": port, "http-port": http-server.port} --network="all" --services="all"
    expect-sandbox "public" {"port": port} --network="public"
    expect-sandbox "unlimited" {"port": port, "other-port": other.port}
        --network=["127.0.0.1:$port"]
    limited := {"allow": ["127.0.0.1:$port"], "connections": 1}
    a := start-sandbox "own-limit" {"port": port} --network=limited
    b := start-sandbox "own-limit" {"port": port} --network=limited
    server.wait-open 2
    expect-equals 0 a.wait
    expect-equals 0 b.wait
    server.close
    other.close
    http-server.close
