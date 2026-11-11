// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Support for the sandbox tests.

Every test is a program that runs in three roles, all from the same image:
- the driver: the trusted application container started by toit.run. It
  starts a trusted sibling container and an untrusted container, waits for
  the untrusted container, and checks that the sibling and the VM keep
  running.
- the sibling: a trusted container that provides the $SiblingService.
- the untrusted container: runs the attack and reports through its exit
  code whether the attack ended in the expected exception.
*/

import expect show *
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient
import system.api.service-discovery show ServiceDiscoveryServiceClient

ROLE-KEY ::= "role"
ROLE-UNTRUSTED ::= "untrusted"
ROLE-SIBLING ::= "sibling"

// Exit codes of the untrusted container.
EXIT-ATTACK-FAILED ::= 0     // The attack threw the expected exception.
EXIT-ATTACK-SUCCEEDED ::= 3  // The attack did not throw.
EXIT-WRONG-ERROR ::= 4       // The attack threw an unexpected exception.

// A message type that is not reserved for the system.
USER-MESSAGE-TYPE ::= 100

interface SiblingService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a11"
      --major=1
      --minor=0

  ping value/int -> int
  static PING-INDEX ::= 0

  pid -> int
  static PID-INDEX ::= 1

  // Makes the sibling busy (not processing messages) for $ms milliseconds.
  busy ms/int -> none
  static BUSY-INDEX ::= 2

class SiblingClient extends ServiceClient implements SiblingService:
  static SELECTOR ::= SiblingService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  ping value/int -> int:
    return invoke_ SiblingService.PING-INDEX value

  pid -> int:
    return invoke_ SiblingService.PID-INDEX null

  busy ms/int -> none:
    invoke_ SiblingService.BUSY-INDEX ms

class SiblingProvider extends ServiceProvider implements SiblingService ServiceHandler:
  constructor:
    super "test/sandbox/sibling" --major=1 --minor=0
    provides SiblingService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SiblingService.PING-INDEX: return ping arguments
    if index == SiblingService.PID-INDEX: return pid
    if index == SiblingService.BUSY-INDEX: return busy arguments
    unreachable

  ping value/int -> int:
    return value + 1

  pid -> int:
    return Process.current.id

  busy ms/int -> none:
    task::
      // Spin without yielding, so the process doesn't process messages.
      deadline := Time.monotonic-us + ms * 1000
      while Time.monotonic-us < deadline:
        null

/** Absorbs user messages sent to the sibling. */
class UserMessageSink_ implements SystemMessageHandler_:
  received/int := 0
  on-message type/int gid/int pid/int message/any -> none:
    received++

run-sibling -> none:
  set-system-message-handler_ USER-MESSAGE-TYPE UserMessageSink_
  provider := SiblingProvider
  provider.install
  while true: sleep --ms=50

/**
Runs a sandbox test.

The $attack block is called in the untrusted container with the arguments
  map, which contains the key "sibling-pid". It must throw. If $error is
  not null, the exception must be equal to it (or contained in it, if it is
  a list).

If $exit is not $EXIT-ATTACK-FAILED, the untrusted container is expected
  to be terminated by the VM with that exit code.

If $busy-sibling-ms is not null, the sibling is made busy (it doesn't
  process messages) for that many milliseconds right before the untrusted
  container is started.

The untrusted container runs with the untrusted policy and the given
  $quotas. If $trusted is true, it runs with the trusted policy and the
  given $quotas instead (for the quotas that only apply to code that has
  the corresponding primitives).

If $prepare is not null, it is called in the driver (with the client of
  the sibling) before the untrusted container is started, and the map it
  returns is added to the arguments of the untrusted container.

If $during is not null, it is called in the driver (with the client of
  the sibling) in a separate task while the untrusted container runs. The
  driver waits for it to return before it checks the sibling; an exception
  in it fails the test.
*/
sandbox-test arguments/any -> none
    --error/any=null
    --exit/int=EXIT-ATTACK-FAILED
    --quotas/Map?=null
    --trusted/bool=false
    --busy-sibling-ms/int?=null
    --prepare/Lambda?=null
    --during/Lambda?=null
    [attack]:
  if arguments is Map:
    role := arguments.get ROLE-KEY
    if role == ROLE-SIBLING:
      run-sibling
      return
    if role == ROLE-UNTRUSTED:
      run-attack arguments attack
      return
    throw "Unknown role: $role"
  run-driver --error=error --exit=exit --quotas=quotas --trusted=trusted --busy-sibling-ms=busy-sibling-ms --prepare=prepare --during=during

run-attack arguments/Map [attack] -> none:
  exception := catch: attack.call arguments
  if exception == null:
    print "ATTACK SUCCEEDED"
    exit EXIT-ATTACK-SUCCEEDED
  expected := arguments.get "error"
  matches := expected == null
      or exception == expected
      or (expected is List and expected.contains exception)
  if not matches:
    print "UNEXPECTED EXCEPTION: $exception (expected $expected)"
    exit EXIT-WRONG-ERROR
  print "attack failed as expected: $exception"
  exit EXIT-ATTACK-FAILED

run-driver --error/any --exit/int --quotas/Map? --trusted/bool --busy-sibling-ms/int? --prepare/Lambda? --during/Lambda? -> none:
  sibling-stopped := false
  sibling := containers.start containers.current {ROLE-KEY: ROLE-SIBLING}
      --on-stopped=:: sibling-stopped = true
  client := SiblingClient
  client.open --timeout=(Duration --s=5)
  expect-equals 2 (client.ping 1)
  sibling-pid := client.pid

  untrusted-arguments := {
    ROLE-KEY: ROLE-UNTRUSTED,
    "error": error,
    "sibling-pid": sibling-pid,
  }
  if prepare:
    (prepare.call client).do: | key value | untrusted-arguments[key] = value
  if busy-sibling-ms: client.busy busy-sibling-ms
  sandboxed := containers.start containers.current untrusted-arguments
      --untrusted=(not trusted)
      --quotas=quotas
  during-done := monitor.Latch
  if during:
    task::
      exception := catch --trace: during.call client
      during-done.set exception
  else:
    during-done.set null
  code := sandboxed.wait
  expect-equals exit code
  expect-null during-done.get

  // The VM, the driver and the sibling keep running and the sibling still
  // answers requests.
  expect-not sibling-stopped
  expect-equals 43 (client.ping 42)
  client.close
  sibling.stop
  print "OK"

/**
Discovers the provider of the service with the given $uuid and returns its
  process id. Discovery grants a sandboxed caller the capability to send
  messages to the provider.
*/
discover-pid uuid/string -> int:
  discovery := ServiceDiscoveryServiceClient
  discovery.open
  try:
    deadline := Time.monotonic-us + 5_000_000
    while Time.monotonic-us < deadline:
      result := discovery.discover uuid --wait=false
      if result and result[0]: return result[0][0]
      sleep --ms=10
    throw "Service not found: $uuid"
  finally:
    discovery.close
