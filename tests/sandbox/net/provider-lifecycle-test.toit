// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The sandbox network provider is an ordinary trusted container:
- when it doesn't run, a sandbox gets "Sandbox network unavailable" after
  a bounded wait;
- a sandbox that starts first waits for it with a timeout;
- when it stops in the middle of a stream (crash or restart), the
  sandbox's calls fail and it can open a new session with the restarted
  provider;
- a sandbox can't register a provider of the network services in its
  place (providing services is a privilege).
*/

import expect show *
import net.sandbox
import system.services show ServiceProvider ServiceHandler
import system.api.sandbox-network show SandboxSocketService
import .net-util

class FakeProvider extends ServiceProvider implements ServiceHandler:
  constructor:
    super "fake/sandbox-network" --major=0 --minor=1
    provides SandboxSocketService.SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    return null

main args:
  run-test args --roles={
    "unavailable": :: | arguments/Map |
      start := Time.monotonic-us
      expect-equals "Sandbox network unavailable" (catch: sandbox.open)
      expect (Time.monotonic-us - start) < 1_000_000,

    "late": :: | arguments/Map |
      // Started before the provider.
      network := sandbox.open --timeout=(Duration --s=10)
      socket := network.tcp-connect "127.0.0.1" arguments["port"]
      socket.out.write "late"
      expect-equals "late" socket.in.read.to-string
      socket.close,

    "restart": :: | arguments/Map |
      port := arguments["port"]
      socket := sandbox.open.tcp-connect "127.0.0.1" port
      socket.out.write "one"
      expect-equals "one" socket.in.read.to-string
      // The driver stops the provider now: the stream fails.
      exception := catch: socket.in.read
      print "read after the provider stopped: $exception"
      expect-not-null exception
      // A new session, with the restarted provider.
      socket = (sandbox.open --timeout=(Duration --s=10)).tcp-connect "127.0.0.1" port
      socket.out.write "two"
      expect-equals "two" socket.in.read.to-string
      socket.close,

    "look-alike": :: | arguments/Map |
      expect-equals "SERVICE_REGISTRATION_DENIED" (catch: (FakeProvider).install)
      // The services library's request handling, set up by the attempt,
      // would keep the process alive.
      exit 0,
  }:
    server := EchoServer
    port := server.port
    network := ["127.0.0.1:$port"]

    expect-sandbox "unavailable"

    late := start-sandbox "late" {"port": port}
    sleep --ms=500
    provider := start-provider --network=network
    expect-equals 0 late.wait

    restart := start-sandbox "restart" {"port": port}
    server.wait-open 1
    sleep --ms=500  // Let the first echo finish.
    provider.stop
    server.wait-open 0
    provider = start-provider --network=network
    expect-equals 0 restart.wait

    expect-sandbox "look-alike"
    provider.stop
    server.close
