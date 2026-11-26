// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: replies that the sandbox's own message
  quotas refuse don't lose or duplicate data. The sandbox runs with a
  mailbox quota smaller than two chunks and echoes on three streams at
  once, so replies of the service are refused (the call fails with
  QUOTA_EXCEEDED); the streams acknowledge what they received and give
  write offsets, so the calls are repeated without loss.
*/

import expect show *
import net.sandbox
import monitor
import system.api.sandbox-network show SandboxStream SandboxNetworkClient
import .net-util

SIZE ::= 200 * 1024

main args:
  run-test args --roles={
    "echo": :: | arguments/Map |
      network := sandbox.open
      done := monitor.Semaphore
      3.repeat: | i |
        task::
          socket := network.tcp-connect "127.0.0.1" arguments["port"]
          data := ByteArray SIZE: (it * 13 + i) & 0xff
          task::
            socket.out.write data
            socket.out.close
          expect-equals data socket.in.read-all
          socket.close
          done.up
      3.repeat: done.down
      print "calls $SandboxNetworkClient.calls, retried after QUOTA_EXCEEDED: $SandboxStream.retried",
  }:
    server := EchoServer
    port := server.port
    expect-sandbox "echo" {"port": port}
        --network={"allow": ["127.0.0.1:$port"], "connections": 3, "bytes-per-second": 1024 * 1024}
        --quotas={"mailbox-bytes": 6000}
    server.close
