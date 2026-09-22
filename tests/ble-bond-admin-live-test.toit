// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.containers
import ble.experimental.bond-registry
import ble.experimental.service.bond-admin-client as clients
import ble.experimental.service.bond-admin-provider as providers
import .ble-bond-revocation-test as fixture

main arguments:
  if arguments is Map:
    client := Client
    client.open --timeout=(Duration --s=5)
    try:
      if arguments["deadline"]:
        expect-throw DEADLINE-EXCEEDED-ERROR:
          client.revoke 0 --timeout=(Duration --ms=200)
        client.await-unwind
        expect-throw "BLE_BOND_REGISTRY_FAILED": client.revoke 1
        client.finished "ADMIN_REQUEST_TIMED_OUT"
      else if arguments["cancel-task"]:
        cancel-request client
      else:
        inventory := client.bonds
        error := catch: client.revoke-bond inventory[0]
        client.finished error
    finally:
      client.close
    return
  with-timeout --ms=15_000:
    fixture.run --managed --revoker=Revoker
    fixture.run --managed --deletion-fails --revoker=Revoker
    fixture.run --managed --cancel-delete --revoker=Revoker
    fixture.run --managed --cancel-delete --revoker=(Revoker --no-stop)
    fixture.run --managed --cancel-delete --revoker=(Revoker --no-stop --deadline)

cancel-request client/Client:
  returned := false
  ended := monitor.Latch
  waiter := task::
    try:
      client.revoke 0
      returned = true
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    client.await-cancel
    waiter.cancel
    ended.get
    expect (not returned)
    client.await-unwind
    // The same client is still usable: failure comes from registry policy,
    // not a vanished caller/provider or a closed RPC channel.
    expect-throw "BLE_BOND_REGISTRY_FAILED": client.revoke 1
    client.finished "ADMIN_REQUEST_CANCELLED"
  finally:
    waiter.cancel

class Client extends clients.Client:
  constructor: super
  finished error/any -> none: invoke_ 1000 error
  await-cancel -> none: invoke_ 1001 null
  await-unwind -> none: invoke_ 1002 null

class Provider extends providers.Provider:
  result/monitor.Latch ::= monitor.Latch
  ended/monitor.Latch ::= monitor.Latch
  cancel-request/monitor.Latch ::= monitor.Latch
  administrator_/int
  constructor registry/bond-registry.Registry .administrator_:
    super registry --administrator-gid=administrator_
  handle index/int arguments/any --gid/int --client/int -> any:
    if 1000 <= index <= 1002:
      // Test-only result and ordering channels, absent from the real API.
      expect-equals administrator_ gid
      if index == 1000: result.set arguments
      else if index == 1001: cancel-request.get
      else: ended.get
      return null
    try:
      return super index arguments --gid=gid --client=client
    finally:
      if index == 0 or index == 3:
        critical-do --no-respect-deadline: ended.set true

class Revoker extends fixture.Revoker:
  stop_/bool
  deadline_/bool
  application_/containers.Container? := null
  provider_/Provider? := null
  constructor --stop/bool=true --deadline/bool=false:
    stop_ = stop
    deadline_ = deadline
  remove registry/bond-registry.Registry -> none:
    application := containers.start containers.current {"cancel-task": not stop_, "deadline": deadline_}
    provider := Provider registry application.gid
    application_ = application
    provider_ = provider
    provider.install
    try:
      error := provider.result.get
      expect-equals 0 application.wait
      if error: throw error
    finally:
      critical-do --no-respect-deadline:
        application.close
        provider.uninstall
        application_ = null
        provider_ = null

  cancel -> none:
    // Interrupt the actual caller only after storage IO is held. Observe the
    // remote unwind before the harness cancels its local waiting task.
    application := application_
    provider := provider_
    if stop_: expect-equals 0 application.stop
    else if not deadline_: provider.cancel-request.set true
    provider.ended.get
    if not stop_: expect-equals 0 application.wait
