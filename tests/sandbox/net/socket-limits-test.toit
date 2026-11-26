// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: the limits of a container's network
  policy (concurrent connections, connection attempts per minute, bytes per
  second, bytes per day) and the limit of all sandboxes together.
*/

import expect show *
import net.sandbox
import .net-util

main args:
  run-test args --roles={
    "connections": :: | arguments/Map |
      network := sandbox.open
      port := arguments["port"]
      a := network.tcp-connect "127.0.0.1" port
      b := network.tcp-connect "127.0.0.1" port
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: network.tcp-connect "127.0.0.1" port)
      a.close
      c := network.tcp-connect "127.0.0.1" port
      c.out.write "c"
      expect-equals "c" c.in.read.to-string
      b.close
      c.close,

    "attempts": :: | arguments/Map |
      network := sandbox.open
      port := arguments["port"]
      3.repeat: (network.tcp-connect "127.0.0.1" port).close
      // Denied requests are no attempts.
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" port + 1)
      // The fourth attempt in a minute is refused.
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: network.tcp-connect "127.0.0.1" port),

    "rate": :: | arguments/Map |
      network := sandbox.open
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      start := Time.monotonic-us
      data := pattern 8192
      task:: socket.out.write data
      // The writes wait for the service (the rate): the bytes must arrive
      // unchanged.
      received := ByteArray 0
      while received.size < data.size: received += socket.in.read
      expect-equals data received
      elapsed-ms := (Time.monotonic-us - start) / 1000
      print "16 KB at 4 KB/s: $elapsed-ms ms"
      // 16 KB in both directions together, with a burst of 4 KB: at least
      // 3 s.
      expect elapsed-ms >= 2_500
      socket.close,

    "day": :: | arguments/Map |
      network := sandbox.open
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      socket.out.write (pattern 4096)
      // The echo takes the day's total over 6000 bytes.
      exception := catch:
        while socket.in.read: null
      expect-equals "NETWORK_QUOTA_EXCEEDED" exception
      socket.close
      // The day's bytes are used up for new connections too.
      socket = network.tcp-connect "127.0.0.1" arguments["port"]
      exception = catch:
        socket.out.write (pattern 4096)
        socket.in.read
      expect-equals "NETWORK_QUOTA_EXCEEDED" exception,

    "hold": :: | arguments/Map |
      network := sandbox.open
      sockets := List arguments["count"]: network.tcp-connect "127.0.0.1" arguments["port"]
      while true: sleep --ms=100,

    "one": :: | arguments/Map |
      expect-equals arguments["expected"]
          catch: (sandbox.open.tcp-connect "127.0.0.1" arguments["port"]).close,
  }:
    server := EchoServer
    port := server.port
    allow := ["127.0.0.1:$port"]
    expect-sandbox "connections" {"port": port}
        --network={"allow": allow, "connections": 2}
    expect-sandbox "attempts" {"port": port}
        --network={"allow": allow, "attempts-per-minute": 3}
    expect-sandbox "rate" {"port": port}
        --network={"allow": allow, "bytes-per-second": 4096}
    expect-sandbox "day" {"port": port}
        --network={"allow": allow, "bytes-per-day": 6000}

    // All sandboxes together have at most 8 connections.
    holder := start-sandbox "hold" {"port": port, "count": 8}
        --network={"allow": allow, "connections": 8}
    server.wait-open 8
    expect-sandbox "one" {"port": port, "expected": "NETWORK_QUOTA_EXCEEDED"}
        --network={"allow": allow}
    holder.stop
    server.wait-open 0
    expect-sandbox "one" {"port": port, "expected": null}
        --network={"allow": allow}
    server.close
