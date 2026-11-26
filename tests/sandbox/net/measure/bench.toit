// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Measures the sandbox network variants against a local HTTP server.

Usage: bench.toit MODE OP N [trusted] [sample] [live]
  MODE: s-http (the http package over variant S, one kept-alive
    connection), s-raw (a raw HTTP/1.1 request per connection over
    variant S), h (variant H, a connection per request), direct (the http
    package on the trusted network, no service).
  OP: download (N downloads of 100 KB) or small (N requests of 5 bytes).
  N: 0 runs the setup only.
  trusted: run the client as a trusted container (with the same network
    policy), so it can sample its own heap.
  live: sample the heaps after a collection (every 10 ms), not their size
    with garbage (every 2 ms).
Prints the client's RPC calls and notifications, and the peaks of the
  system process's heap (and with trusted, the client's).
*/

import http
import net
import net.sandbox
import net.sandbox-http
import system
import system.containers
import system.api.sandbox-network show SandboxNetworkClient SandboxStream
import ..net-util

SIZE ::= 100 * 1024

main args:
  if args is Map:
    run-client args
    return
  mode := args[0]
  op := args[1]
  n := int.parse args[2]
  trusted := args.contains "trusted"
  server := HttpServer
  port := server.port
  live := args.contains "live"
  // Without "sample" or "live" no sampling (for instruction counts).
  peak := (live or args.contains "sample") ? (PeakSampler 0 SYSTEM-PROCESS-ID_ --live=live) : null
  container := containers.start containers.current
      {"role": "client", "mode": mode, "op": op, "n": n, "port": port, "trusted": trusted, "live": live}
      --untrusted=(mode != "direct" and not trusted)
      --services=[SOCKET-SERVICE, HTTP-SERVICE]
      --network={
        "allow": ["127.0.0.1:$port"],
        "connections": 8,
        "attempts-per-minute": 600,
        "bytes-per-second": 1024 * 1024,
        "bytes-per-day": 1 << 30,
        "response-bytes": 1 << 20,
      }
  code := container.wait
  if peak:
    peak.stop
    print "system process: heap allocated $peak.base-allocated -> peak $peak.max-allocated (+$(peak.max-allocated - peak.base-allocated)), reserved $peak.base-reserved -> peak $peak.max-reserved"
  print "server requests: $server.requests"
  server.close
  exit code

class PeakSampler:
  base-allocated/int := 0
  base-reserved/int := 0
  max-allocated/int := 0
  max-reserved/int := 0
  task_/Task? := null

  constructor gid/int? pid/int? --live/bool=false:
    stats := gid ? (system.process-stats --gc gid pid) : system.process-stats --gc
    base-allocated = stats[system.STATS-INDEX-ALLOCATED-MEMORY]
    base-reserved = stats[system.STATS-INDEX-RESERVED-MEMORY]
    task_ = task --background::
      while true:
        s := gid ? (system.process-stats --gc=live gid pid) : system.process-stats --gc=live
        if s:
          max-allocated = max max-allocated s[system.STATS-INDEX-ALLOCATED-MEMORY]
          max-reserved = max max-reserved s[system.STATS-INDEX-RESERVED-MEMORY]
        sleep --ms=(live ? 10 : 2)

  stop -> none:
    task_.cancel

run-client args/Map -> none:
  mode := args["mode"]
  op := args["op"]
  n := args["n"]
  port := args["port"]
  peak := args["trusted"] ? (PeakSampler null null --live=args["live"]) : null
  path := op == "download" ? "/big?n=$SIZE" : "/small"
  expected := op == "download" ? SIZE : 5
  start := Time.monotonic-us
  if mode == "s-http" or mode == "direct":
    network := mode == "direct" ? net.open : sandbox.open
    client := http.Client network
    n.repeat:
      response := client.get "127.0.0.1" --port=port path
      size := 0
      while chunk := response.body.read: size += chunk.size
      if size != expected: throw "wrong size $size"
    client.close
  else if mode == "s-raw":
    network := sandbox.open
    n.repeat:
      socket := network.tcp-connect "127.0.0.1" port
      socket.out.write "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n"
      // The server keeps the connection open: read the head, then the body
      // by its content length.
      length := 0
      while line := socket.in.read-line:
        if line == "": break
        if line.to-ascii-lower.starts-with "content-length:": length = int.parse line[15..].trim
      body := socket.in.read-bytes length
      socket.close
      if body.size != expected: throw "wrong size $body.size"
  else:
    client := sandbox-http.open
    n.repeat:
      response := client.get "http://127.0.0.1:$port$path"
      size := 0
      while chunk := response.body.read: size += chunk.size
      response.close
      if size != expected: throw "wrong size $size"
  elapsed := (Time.monotonic-us - start) / 1000
  print "client $mode $op n=$n: $elapsed ms, calls $SandboxNetworkClient.calls, notifications $SandboxStream.notifications"
  if peak:
    peak.stop
    print "client heap: allocated $peak.base-allocated -> peak $peak.max-allocated, reserved $peak.base-reserved -> peak $peak.max-reserved"
