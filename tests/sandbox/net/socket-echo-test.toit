// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: a sandbox reaches a local echo server
  through the sandbox socket service only when its policy allows the
  destination, and only through the service when its service list allows
  that.
*/

import expect show *
import net.sandbox
import system.api.sandbox-network show SandboxSocketService
import .net-util
import ..sandbox show provider-ids open-without-discovery

main args:
  run-test args --roles={
    "echo": :: | arguments/Map |
      network := sandbox.open
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      socket.out.write "hello"
      expect-equals "hello" socket.in.read.to-string
      // The writer and reader classes of the io library work on it.
      socket.out.write (pattern 10_000)
      socket.out.close
      expect-equals (pattern 10_000) socket.in.read-all
      socket.close,

    "denied": :: | arguments/Map |
      network := sandbox.open
      port := arguments["port"]
      // Not on the list: another port, another address, a name, an
      // address in a private network.
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" port + 1)
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.2" port)
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "example.com" 80)
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "10.0.0.1" port)
      // Malformed host names are denied as well.
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1:$port" port)
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "" port),

    "rebinding": :: | arguments/Map |
      network := sandbox.open
      port := arguments["port"]
      // The name is allowed, but it resolves to a loopback address, which
      // only a rule with the address itself allows. The error doesn't say
      // whether the name exists.
      expect-equals "CONNECT_FAILED" (catch: network.tcp-connect "localhost" port)
      // The client can't pass the address the name resolves to instead.
      expect-equals "NETWORK_DENIED" (catch: network.tcp-connect "127.0.0.1" port),

    "rebinding-listed": :: | arguments/Map |
      // With the address on the list as well, the name works.
      socket := sandbox.open.tcp-connect "localhost" arguments["port"]
      socket.out.write "x"
      expect-equals "x" socket.in.read.to-string
      socket.close,

    "not-listed": :: | arguments/Map |
      // The service isn't on the container's service list: the sandbox
      // doesn't discover it and can't open it without discovery either.
      expect-equals "Sandbox network unavailable" (catch: sandbox.open)
      ids := arguments["ids"]
      expect-equals "PERMISSION_DENIED"
          catch: open-without-discovery ids[0] ids[1] SandboxSocketService.SELECTOR,

    "no-policy": :: | arguments/Map |
      // On the list, but without a network policy.
      expect-equals "NETWORK_DENIED" (catch: sandbox.open.tcp-connect "127.0.0.1" arguments["port"]),
  }:
    server := EchoServer
    port := server.port
    expect-sandbox "echo" {"port": port}
        --network={"allow": ["127.0.0.1:$port"]}
    expect-sandbox "denied" {"port": port}
        --network={"allow": ["127.0.0.1:$port"]}
    expect-sandbox "rebinding" {"port": port}
        --network={"allow": ["localhost:$port"]}
    expect-sandbox "rebinding-listed" {"port": port}
        --network={"allow": ["localhost:$port", "127.0.0.1:$port"]}
    expect-sandbox "not-listed" {"port": port, "ids": provider-ids SOCKET-SERVICE}
        --services=[HTTP-SERVICE]
        --network={"allow": ["127.0.0.1:$port"]}
    expect-sandbox "no-policy" {"port": port}
    server.close
