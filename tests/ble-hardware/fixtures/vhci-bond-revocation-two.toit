// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.security-owner show Owner
import ble.experimental.service.client as clients
import ble.experimental.service.bond-admin-client as admin
import ble.experimental.service.bond-admin-provider as administration
import ble.experimental.service.provider as rpc
import system
import system.containers
import .vhci-bond-admin-live as live
import .vhci-bond-revocation-peer as fixture
import .vhci-revocation-pair as pairing-fixture

main arguments: run arguments

run arguments --private/bool=false --authenticated/bool=false
    --first-peer/ByteArray?=null --receive-acl-packets/int=0 --trace/bool=false:
  live.trace-hci = trace
  if private and authenticated: throw "UNSUPPORTED_FIXTURE_COMBINATION"
  if first-peer and not authenticated: throw "UNSUPPORTED_FIXTURE_COMBINATION"
  with-timeout --ms=(authenticated ? 120_000 : 60_000):
    if arguments is Map:
      application arguments["provider"] --private=private --authenticated=authenticated --first-peer=first-peer
    else:
      table := ble-table --private=private --authenticated=authenticated
      // Seed only this fixture's dedicated namespace; other bonds are untouched.
      table.remove 0
      table.remove 1
      registry := bond-registry.Registry table --owner-limit=2
      candidates := authenticated
          ? (pairing-fixture.pair --first-peer=first-peer --receive-acl-packets=receive-acl-packets --trace=trace)
          : (List 2: fixture.candidate it --private=private)
      2.repeat: | index/int |
        if (registry.add candidates[index]) != index: throw "REVOKE_TWO_SLOT"
      provider := Provider registry --private=private --authenticated=authenticated --receive-acl-packets=receive-acl-packets
      provider.install
      child := containers.start containers.current {"provider": Process.current.id}
      provider.application-gid = child.gid
      administrator := administration.Provider registry --administrator-gid=child.gid
      administrator.install
      try:
        if child.wait != 0: throw "REVOKE_TWO_CHILD_FAILED"
        with-timeout --ms=5_000:
          provider.sessions.do: while not it.is-released: sleep --ms=1
        if provider.opens != 1 or provider.radios.size != 1 or provider.sessions.size != 3:
          throw "REVOKE_TWO_WRONG_LIFETIMES"
        radio/live.Radio := provider.radios[0]
        if radio.disconnections != 3 or radio.encryptions != 2: throw "REVOKE_TWO_RADIO_COUNTS"
        if private:
          if provider.locals.size != 3: throw "REVOKE_TWO_LOCAL_COUNT"
          3.repeat: | index/int |
            if provider.locals[index] != (fixture.central-rpa index): throw "REVOKE_TWO_LOCAL_ROTATION"
        if table.load 0: throw "REVOKE_TWO_DELETION_FAILED"
        if (table.load 1).encode != candidates[1].encode: throw "REVOKE_TWO_SURVIVOR_BOND_CHANGED"
      finally:
        critical-do --no-respect-deadline:
          child.close
          administrator.uninstall
          provider.uninstall
          registry.close
      table = ble-table --private=private --authenticated=authenticated
      try:
        if table.load 0 or (table.load 1).encode != candidates[1].encode:
          throw "REVOKE_TWO_REOPEN_FAILED"
      finally:
        table.close
      print "REVOKE_TWO COMPLETE child-exit=0 controller-opens=1 sessions=3 disconnections=3 encryptions=2 storage-reopened=true private=$private authenticated=$authenticated"

ble-table --private/bool=false --authenticated/bool=false -> bond-table.Table:
  path := authenticated ? "toit.test/revoke-auth-v1" : (private ? "toit.test/revoke-private-v1" : "toit.test/revoke-two-v1")
  return bond-table.Table (bond-flash.FlashRecords path) (ByteArray 32: it) --capacity=2

application pid/int --private/bool=false --authenticated/bool=false --first-peer/ByteArray?=null:
  first-client := Client --provider-pid=pid
  second-client := clients.Client --provider-pid=pid
  administrator := admin.Client --provider-pid=pid
  first-client.open
  second-client.open
  administrator.open
  first/clients.Connection? := null
  second/clients.Connection? := null
  try:
    first = first-client.connect (first-peer or (fixture.peer-air-address 0 --private=private)) --address-type=(private ? 1 : 0) --require-encryption --require-authentication=authenticated
    second = second-client.connect (fixture.peer-air-address 1 --private=private) --address-type=(private ? 1 : 0) --require-encryption --require-authentication=authenticated
    if private and (first.info[1] != 1 or second.info[1] != 1): throw "REVOKE_TWO_PEER_ADDRESS_TYPES"
    handles := [value-handle first, value-handle second]
    retained := [first.read handles[0], second.read handles[1]]
    100.repeat:
      check first handles[0] 42 --authenticated=authenticated
      check second handles[1] 43 --authenticated=authenticated
    inventory := administrator.bonds
    if inventory.size != 2: throw "REVOKE_TWO_BAD_INVENTORY"
    inventory.do: | item |
      if item.authenticated != authenticated: throw "REVOKE_TWO_INVENTORY_AUTHENTICATION"
      expected := item.slot == 0 and first-peer ? first-peer : (fixture.peer-address item.slot)
      if item.peer-address-type != 0 or item.peer-address != expected:
        throw "REVOKE_TWO_INVENTORY_NOT_IDENTITY"
    selected := inventory.first.slot == 0 ? inventory.first : inventory.last
    administrator.revoke-bond selected
    failure := catch: first.read handles[0]
    if not failure: throw "REVOKE_TWO_REVOKED_READ_SUCCEEDED"
    first.close
    first-client.wait-first
    100.repeat:
      check second handles[1] 43 --authenticated=authenticated
      system.process-stats --gc
      if retained[0] != #[42] or retained[1] != #[43]: throw "REVOKE_TWO_RETAINED_CHANGED"
    remaining := administrator.bonds
    if remaining.size != 1 or remaining.first.slot != 1: throw "REVOKE_TWO_SURVIVOR_MISSING"
    if (catch: first-client.connect (first-peer or (fixture.peer-air-address 0 --phase=1 --private=private)) --address-type=(private ? 1 : 0) --require-encryption) != "BLE_BOND_NOT_FOUND":
      throw "REVOKE_TWO_RECONNECT_NOT_DENIED"
    check second handles[1] 43 --authenticated=authenticated
    second.disconnect
    print "REVOKE_TWO CLIENT first-reads=101 survivor-reads=202 retained=true reconnect-denied=true"
  finally:
    if first: first.close
    if second: second.close
    administrator.close
    second-client.close
    first-client.close

value-handle connection/clients.Connection -> int:
  services := connection.database.discover-services.filter: it.uuid == #[0xf0, 0xff]
  if services.size != 1: throw "REVOKE_TWO_SERVICE_MISSING"
  values := services[0].characteristics.filter: it.uuid == #[0xf1, 0xff]
  if values.size != 1: throw "REVOKE_TWO_VALUE_MISSING"
  return values[0].handle

check connection/clients.Connection handle/int expected/int --authenticated/bool=false:
  state := connection.security
  if not state.encrypted or state.authenticated != authenticated: throw "REVOKE_TWO_SECURITY"
  if (connection.read handle) != #[expected]: throw "REVOKE_TWO_VALUE"

class Client extends clients.Client:
  constructor --provider-pid/int: super --provider-pid=provider-pid
  wait-first -> none: invoke_ 1000 null

class Provider extends live.Provider:
  sessions/List ::= []
  application-gid/int := -1
  registry_/bond-registry.Registry
  private_/bool
  authenticated_/bool
  next-local_/int := 0
  locals/List ::= []
  constructor .registry_ --private/bool=false --authenticated/bool=false --receive-acl-packets/int=0:
    private_ = private
    authenticated_ = authenticated
    super registry_ --receive-acl-packets=receive-acl-packets
  central-local-random-address info/hci.Capabilities -> ByteArray?:
    if not private_: return null
    address := fixture.central-rpa next-local_
    next-local_++
    return address
  create-central-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    local := link.local-random-address or info.address
    if private_:
      if not (privacy.resolves fixture.central-irk local 1): throw "REVOKE_TWO_LOCAL_IDENTITY"
      locals.add local.copy
    return registry_.resume host link --local-address=local --require-authentication=authenticated_
  create-connection client/int arguments/List -> rpc.Session:
    session := super client arguments
    sessions.add session
    return session
  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 1000:
      if gid != application-gid: throw "REVOKE_TWO_CONTROL_DENIED"
      with-timeout --ms=5_000:
        while not sessions[0].is-released: sleep --ms=1
      return null
    return super index arguments --gid=gid --client=client
