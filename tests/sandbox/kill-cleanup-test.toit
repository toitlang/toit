// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import system.api.service-discovery show ServiceDiscoveryServiceClient
import .sandbox

/**
Nothing of a sandbox survives its kill.

The untrusted container provides a service that the driver uses, has
  messages queued in the (busy) sibling's mailbox, a pending discovery
  (a resource in the system process), timers, tasks and finalizers. Then
  it spins until the VM kills it for exceeding its CPU budget. Afterwards
  its service must be gone from discovery, the driver's client of it must
  fail instead of hanging, and the sibling and the system process must
  work (checked by the harness).
*/

interface EchoService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a13"
      --major=1
      --minor=0

  echo value/any -> any
  static ECHO-INDEX ::= 0

class EchoClient extends ServiceClient implements EchoService:
  constructor:
    super EchoService.SELECTOR

  echo value/any -> any:
    return invoke_ EchoService.ECHO-INDEX value

class EchoProvider extends ServiceProvider implements EchoService ServiceHandler:
  constructor:
    super "test/sandbox/echo" --major=1 --minor=0
    provides EchoService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == EchoService.ECHO-INDEX: return echo arguments
    unreachable

  echo value/any -> any:
    return value

class Finalized_:
  value/int
  constructor .value:

discovered -> bool:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  result := discovery.discover EchoService.SELECTOR.uuid --no-wait
  discovery.close
  return result[0] != null

probe client/SiblingClient -> none:
  echo := EchoClient
  echo.open --timeout=(Duration --s=10)
  expect-equals "hello" (echo.echo "hello")
  // Wait for the kill.
  deadline := Time.monotonic-us + 20_000_000
  while discovered:
    expect Time.monotonic-us < deadline
    sleep --ms=50
  exception := catch: with-timeout --ms=5_000: echo.echo "again"
  print "driver: call after the kill: $exception"
  expect-not-null exception
  expect-not (exception == DEADLINE-EXCEEDED-ERROR)
  echo.close

main args:
  sandbox-test args
      --exit=containers.EXIT-CPU-BUDGET
      --quotas={"cpu-ms": 1_500}
      --busy-sibling-ms=3_000
      --during=(:: probe it): | arguments/Map |
    sibling := discover-pid SiblingService.SELECTOR.uuid
    // Messages left in the sibling's mailbox.
    catch: 100.repeat: process-send_ sibling USER-MESSAGE-TYPE (ByteArray 1000)
    // A pending discovery (a resource in the system process).
    discovery := ServiceDiscoveryServiceClient
    discovery.open
    discovery.discover "no-such-service" --wait
    // Timers, tasks and finalizers.
    5.repeat: task:: while true: sleep --ms=10
    5.repeat: add-finalizer (Finalized_ it):: null
    // A service the driver uses.
    (EchoProvider).install
    sleep --ms=500
    while true: null
