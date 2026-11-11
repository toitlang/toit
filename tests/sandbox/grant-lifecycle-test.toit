// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the life cycle of a messaging grant.

- Before the discovery: the untrusted container knows the provider's pid
  (the driver tells it) and sends to it from a second task while it
  discovers the provider. Every send that happens before the discovery
  returns is denied; once the discovery returned, sends are allowed (the
  grant is issued before the system process replies).
- After the provider died: sends to its pid are allowed but report that
  the receiver is gone (the grant is inert), they don't throw.
- A new provider gets a new, larger pid (pids are not reused), and the
  old grant doesn't cover it: sends to it, and to every pid in between,
  are denied until the new provider is discovered.
*/

import expect show *
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import system.api.service-discovery show ServiceDiscoveryServiceClient

ROLE-KEY ::= "role"
USER-MESSAGE-TYPE ::= 100

interface PidService:
  static SELECTOR ::= ServiceSelector
      --uuid="b0c6a3f2-5e1d-4c8b-9a7f-3d2e1c0b9a11"
      --major=1
      --minor=0

  pid -> int
  static PID-INDEX ::= 0

class PidClient extends ServiceClient implements PidService:
  constructor:
    super PidService.SELECTOR

  pid -> int:
    return invoke_ PidService.PID-INDEX null

class PidProvider extends ServiceProvider implements PidService ServiceHandler:
  constructor:
    super "test/pid" --major=1 --minor=0
    provides PidService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PidService.PID-INDEX: return pid
    unreachable

  pid -> int:
    return Process.current.id

class Sink_ implements SystemMessageHandler_:
  on-message type/int gid/int pid/int message/any -> none:

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "provider":
      set-system-message-handler_ USER-MESSAGE-TYPE Sink_
      (PidProvider).install
      while true: sleep --ms=100
    else if role == "untrusted":
      run-untrusted arguments["provider-pid"]
    else:
      throw "Unknown role: $role"
    return
  run-driver

provider-pid -> int:
  client := PidClient
  client.open --timeout=(Duration --s=5)
  pid := client.pid
  client.close
  return pid

run-driver:
  first := containers.start containers.current {ROLE-KEY: "provider"}
  first-pid := provider-pid
  untrusted := containers.start containers.current
      {ROLE-KEY: "untrusted", "provider-pid": first-pid}
      --untrusted
  // Let the untrusted container discover and use the first provider.
  sleep --ms=1_000
  first.stop
  second := containers.start containers.current {ROLE-KEY: "provider"}
  expect-equals 0 untrusted.wait
  second.stop
  print "OK"

send pid/int -> any:
  result := null
  exception := catch: result = process-send_ pid USER-MESSAGE-TYPE "hello"
  return exception or result

run-untrusted first/int -> none:
  // Race the discovery: a second task sends to the provider all along.
  // Phase 0: before the discovery request, 1: while it is pending,
  // 2: after it returned.
  phase := 0
  results := [{}, {}, {}]
  racing := true
  task::
    while racing:
      current := phase
      result := send first
      // A full mailbox means the send passed the gate.
      results[current].add (result == "QUOTA_EXCEEDED" ? "true" : "$result")
      yield
  sleep --ms=20
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  phase = 1
  result := discovery.discover PidService.SELECTOR.uuid --wait=false
  expect-equals first result[0][0]
  phase = 2
  sleep --ms=20
  racing = false
  expect-equals {"PERMISSION_DENIED"} results[0]
  // While the request is pending, the grant is issued at some point.
  expect (results[1].every: it == "PERMISSION_DENIED" or it == "true")
  expect-equals {"true"} results[2]

  // Wait for the first provider to die. Its grant stays, but is inert.
  deadline := Time.monotonic-us + 10_000_000
  while (send first) != false:
    expect Time.monotonic-us < deadline
    sleep --ms=10
  expect-equals false (send first)

  // Wait for the second provider; until we discover it, we can't reach it.
  second := null
  while not second:
    expect Time.monotonic-us < deadline
    result = discovery.discover PidService.SELECTOR.uuid --wait=false
    if result[0] and result[0][0] != first: second = result[0][0]
    else: sleep --ms=10
  expect second > first
  discovery.close
  expect-equals true (send second)
  // Pids between the two (and after) are not reachable.
  for pid := first + 1; pid < second + 10; pid++:
    if pid == second or pid == Process.current.id: continue
    expect-equals "PERMISSION_DENIED" (send pid)
