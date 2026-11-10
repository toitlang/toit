// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Heat-pump demo: an untrusted control program reaches the heat-pump driver
  (a trusted provider container) only through service discovery, and it
  can't reach a second broker (another trusted provider) that it did not
  discover, even when it knows its process id.
*/

import expect show *
import rpc
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

ROLE-KEY ::= "role"

interface HeatPumpService:
  static SELECTOR ::= ServiceSelector
      --uuid="8c3f6d2e-1a4b-4e7c-9f2d-6b5a4c3d2e1f"
      --major=1
      --minor=0

  set-target celsius/int -> none
  static SET-TARGET-INDEX ::= 0

  target -> int
  static TARGET-INDEX ::= 1

class HeatPumpClient extends ServiceClient implements HeatPumpService:
  static SELECTOR ::= HeatPumpService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR --provider-pid/int?=null:
    super selector --provider-pid=provider-pid

  set-target celsius/int -> none:
    invoke_ HeatPumpService.SET-TARGET-INDEX celsius

  target -> int:
    return invoke_ HeatPumpService.TARGET-INDEX null

class HeatPumpProvider extends ServiceProvider implements HeatPumpService ServiceHandler:
  target_/int := 18

  constructor:
    super "test/heat-pump" --major=1 --minor=0
    provides HeatPumpService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == HeatPumpService.SET-TARGET-INDEX: return set-target arguments
    if index == HeatPumpService.TARGET-INDEX: return target
    unreachable

  set-target celsius/int -> none:
    if not 5 <= celsius <= 30: throw "OUT_OF_RANGE"
    target_ = celsius

  target -> int:
    return target_

// A second broker (for example, the one controlling the door lock).
interface BrokerService:
  static SELECTOR ::= ServiceSelector
      --uuid="2d4e6f80-9a1b-4c3d-8e5f-7a6b5c4d3e2f"
      --major=1
      --minor=0

  opened -> int
  static OPENED-INDEX ::= 0

  pid -> int
  static PID-INDEX ::= 1

  received -> int
  static RECEIVED-INDEX ::= 2

class BrokerClient extends ServiceClient implements BrokerService:
  static SELECTOR ::= BrokerService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    super selector

  opened -> int:
    return invoke_ BrokerService.OPENED-INDEX null

  pid -> int:
    return invoke_ BrokerService.PID-INDEX null

  received -> int:
    return invoke_ BrokerService.RECEIVED-INDEX null

class BrokerProvider extends ServiceProvider implements BrokerService ServiceHandler SystemMessageHandler_:
  opened_/int := 0
  received_/int := 0

  constructor:
    super "test/broker" --major=1 --minor=0
    provides BrokerService.SELECTOR --handler=this
    set-system-message-handler_ 100 this

  on-opened client/int -> none:
    opened_++

  on-message type/int gid/int pid/int message/any -> none:
    received_++

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == BrokerService.OPENED-INDEX: return opened
    if index == BrokerService.PID-INDEX: return pid
    if index == BrokerService.RECEIVED-INDEX: return received
    unreachable

  opened -> int: return opened_
  pid -> int: return Process.current.id
  received -> int: return received_

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "heat-pump":
      (HeatPumpProvider).install
      while true: sleep --ms=50
    else if role == "broker":
      (BrokerProvider).install
      while true: sleep --ms=50
    else if role == "controller":
      run-controller arguments["broker-pid"]
    else:
      throw "Unknown role: $role"
    return
  run-driver

run-driver:
  heat-pump := containers.start containers.current {ROLE-KEY: "heat-pump"}
  broker := containers.start containers.current {ROLE-KEY: "broker"}

  heat-pump-client := HeatPumpClient
  heat-pump-client.open --timeout=(Duration --s=5)
  expect-equals 18 heat-pump-client.target
  broker-client := BrokerClient
  broker-client.open --timeout=(Duration --s=5)
  broker-pid := broker-client.pid
  expect-equals 1 broker-client.opened

  controller := containers.start containers.current
      {ROLE-KEY: "controller", "broker-pid": broker-pid}
      --untrusted
  expect-equals 0 controller.wait

  // The controller reached the heat pump...
  expect-equals 21 heat-pump-client.target
  // ... but the broker never heard from it.
  expect-equals 1 broker-client.opened
  expect-equals 0 broker-client.received

  heat-pump-client.close
  broker-client.close
  heat-pump.stop
  broker.stop
  print "OK"

/** The untrusted control program. */
run-controller broker-pid/int:
  // Reaching the heat pump through discovery works.
  heat-pump := HeatPumpClient
  heat-pump.open
  heat-pump.set-target 21
  expect-equals 21 heat-pump.target
  expect-throw "OUT_OF_RANGE": heat-pump.set-target 99

  // The broker was not discovered, so the controller can't send to it, no
  // matter how.
  expect-throw "PERMISSION_DENIED": process-send_ broker-pid 100 "unlock"
  expect-throw "PERMISSION_DENIED":
    rpc.invoke broker-pid 300 [0, BrokerService.SELECTOR.uuid, 1, 0]
  // Using the heat-pump capability with the broker's pid doesn't work.
  expect-throw "Cannot find service":
    (HeatPumpClient --provider-pid=broker-pid).open
  print "controller done"
