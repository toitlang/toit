// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The one-word network policies and the policy lookup per container:
- "all": every destination (loopback included), no limits, and the
  network services without listing them;
- "public": every public address, nothing internal;
- a list of rules: these destinations, no limits;
- two sandboxes with different policies at the same time, each held to its
  own (the provider looks the policy up by the group id the VM gives it).
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

    "own-policy": :: | arguments/Map |
      network := sandbox.open
      // Both sandboxes run at the same time.
      sleep --ms=300
      (network.tcp-connect "127.0.0.1" arguments["allowed"]).close
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" arguments["denied"])
      sleep --ms=300,
  }:
    server := EchoServer
    other := EchoServer
    http-server := HttpServer
    port := server.port
    expect-sandbox "all" {"port": port, "http-port": http-server.port} --network="all"
    expect-sandbox "public" {"port": port} --network="public"
    expect-sandbox "unlimited" {"port": port, "other-port": other.port}
        --network=["127.0.0.1:$port"]
    a := start-sandbox "own-policy" {"allowed": port, "denied": other.port}
        --network=["127.0.0.1:$port"]
    b := start-sandbox "own-policy" {"allowed": other.port, "denied": port}
        --network=["127.0.0.1:$other.port"]
    expect-equals 0 a.wait
    expect-equals 0 b.wait
    server.close
    other.close
    http-server.close
