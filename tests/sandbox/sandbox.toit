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
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

ROLE-KEY ::= "role"
ROLE-UNTRUSTED ::= "untrusted"
ROLE-SIBLING ::= "sibling"

// Exit codes of the untrusted container.
EXIT-ATTACK-FAILED ::= 0     // The attack threw the expected exception.
EXIT-ATTACK-SUCCEEDED ::= 3  // The attack did not throw.
EXIT-WRONG-ERROR ::= 4       // The attack threw an unexpected exception.

interface SiblingService:
  static SELECTOR ::= ServiceSelector
      --uuid="5a1b8e0e-3f0c-4d0e-9d6a-2b7e0d5c9a11"
      --major=1
      --minor=0

  ping value/int -> int
  static PING-INDEX ::= 0

  pid -> int
  static PID-INDEX ::= 1

class SiblingClient extends ServiceClient implements SiblingService:
  static SELECTOR ::= SiblingService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  ping value/int -> int:
    return invoke_ SiblingService.PING-INDEX value

  pid -> int:
    return invoke_ SiblingService.PID-INDEX null

class SiblingProvider extends ServiceProvider implements SiblingService ServiceHandler:
  constructor:
    super "test/sandbox/sibling" --major=1 --minor=0
    provides SiblingService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == SiblingService.PING-INDEX: return ping arguments
    if index == SiblingService.PID-INDEX: return pid
    unreachable

  ping value/int -> int:
    return value + 1

  pid -> int:
    return Process.current.id

run-sibling -> none:
  provider := SiblingProvider
  provider.install
  while true: sleep --ms=50

/**
Runs a sandbox test.

The $attack block is called in the untrusted container with the arguments
  map, which contains the key "sibling-pid". It must throw. If $error is
  not null, the exception must be equal to it (or contained in it, if it is
  a list).

The untrusted container runs with the untrusted policy.
*/
sandbox-test arguments/any -> none
    --error/any=null
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
  run-driver --error=error

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

run-driver --error/any -> none:
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
  sandboxed := containers.start containers.current untrusted-arguments --untrusted
  expect-equals EXIT-ATTACK-FAILED sandboxed.wait

  // The VM, the driver and the sibling keep running and the sibling still
  // answers requests.
  expect-not sibling-stopped
  expect-equals 43 (client.ping 42)
  client.close
  sibling.stop
  print "OK"
