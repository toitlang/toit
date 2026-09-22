// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.containers
import ble.experimental.bond
import ble.experimental.bond-info show BondInfo
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.smp-identity show Identity
import ble.experimental.service.bond-admin-client as clients
import ble.experimental.service.bond-admin-provider as providers
import .ble-bond-table-test as fixture

main arguments:
  if arguments is Map:
    application arguments
    return
  with-timeout --ms=15_000:
    run false
    run true

run fail-delete/bool:
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate (ByteArray 16 --initial=1) identity identity --authenticated
  records := Records
  table := bond-table.Table records (ByteArray 32 --initial=42) --capacity=2
  registry := bond-registry.Registry table
  registry.add candidate
  registry.add candidate
  // The default configuration must deny even a well-formed local request.
  denied := providers.Provider registry
  denied.install
  local := RawClient --provider-pid=Process.current.id
  local.open
  try:
    before := records.operations
    expect-throw "BLE_BOND_ADMIN_DENIED": local.revoke 0
    expect-throw "BLE_BOND_ADMIN_DENIED": local.bonds
    expect-equals before records.operations
  finally:
    local.close
    denied.uninstall
  administrator := containers.start containers.current {"admin": true, "failure": fail-delete, "provider-pid": Process.current.id}
  outsider := containers.start containers.current {"admin": false, "claim": administrator.gid, "provider-pid": Process.current.id}
  provider := Provider registry administrator.gid
  provider.install
  try:
    expect (administrator.gid != outsider.gid)
    before := records.operations
    expect-equals 0 outsider.wait
    // The administrator is held at a fixture barrier until the denial checks
    // finish. Unauthorized calls must not read or mutate protected storage.
    expect-equals before records.operations
    expect-equals [0, 1] table.occupied
    records.ignore-delete = fail-delete
    provider.release.set true
    expect-equals 0 administrator.wait
    expect-equals candidate.encode (table.load 1).encode
    if fail-delete:
      expect-equals candidate.encode (table.load 0).encode
      expect-throw "BLE_BOND_REGISTRY_FAILED": registry.remove 0
    else:
      expect-null (table.load 0)
    // A new instance of the same image has a new group and cannot inherit the
    // previous administrator's grant, even when it supplies that old ID.
    restarted := containers.start containers.current {"admin": false, "claim": administrator.gid, "provider-pid": Process.current.id}
    try:
      expect (restarted.gid != administrator.gid)
      before = records.operations
      expect-equals 0 restarted.wait
      expect-equals before records.operations
    finally:
      restarted.close
  finally:
    provider.release.set true
    administrator.close
    outsider.close
    provider.uninstall
    registry.close
  expect-equals 1 records.closes

application arguments/Map:
  client := RawClient --provider-pid=arguments["provider-pid"]
  client.open --timeout=(Duration --s=5)
  try:
    if not arguments["admin"]:
      [0, 1, 2, 3, 77].do: | index/int |
        [null, 0, -1, 255, [0], {"gid": arguments["claim"], "slot": 0}].do: | payload/any |
          expect-throw "BLE_BOND_ADMIN_DENIED": client.raw index payload
      return
    client.raw 1000 null
    expect-throw "INVALID_ARGUMENT": client.revoke -1
    expect-throw "INVALID_ARGUMENT": client.revoke 0 --timeout=(Duration --us=0)
    expect-throw "INVALID_ARGUMENT": client.raw 0 255
    expect-throw "INVALID_ARGUMENT": client.raw 0 null
    expect-throw "INVALID_ARGUMENT": client.raw 1 0
    expect-throw "INVALID_ARGUMENT": client.raw 2 0
    expect-throw "INVALID_ARGUMENT": client.raw 3 [0, #[]]
    expect-throw "INVALID_ARGUMENT": client.bonds --timeout=(Duration --us=0)
    expect-throw "BLE_BOND_ADMIN_UNSUPPORTED": client.raw 77 null
    inventory := client.bonds
    legacy/List := client.raw 1 null
    expect-equals 2 legacy.size
    expect-equals 6 legacy[0].size
    expect-equals 2 inventory.size
    inventory.size.repeat: | index/int |
      info/BondInfo := inventory[index]
      expect-equals index info.slot
      expect-equals #[1, 2, 3, 4, 5, 6] info.local-address
      expect-equals #[1, 2, 3, 4, 5, 6] info.peer-address
      expect-equals 0 info.local-address-type
      expect-equals 0 info.peer-address-type
      expect info.authenticated
      expect-equals 16 info.revision.size
      revision := info.revision
      revision[0] ^= 1
      expect (info.revision != revision)
      info.local-address.fill 0
      info.peer-address.fill 0
      expect-equals #[1, 2, 3, 4, 5, 6] info.peer-address
    if arguments["failure"]:
      expect-throw "BLE_BOND_DELETE_NOT_VERIFIED": client.revoke 0
      expect-throw "BLE_BOND_REGISTRY_FAILED": client.revoke 0
      expect-throw "BLE_BOND_REGISTRY_FAILED": client.bonds
    else:
      client.revoke-bond inventory[0]
      expect-throw "BLE_STALE_BOND_INVENTORY": client.revoke-bond inventory[1]
      client.revoke 0
      remaining := client.bonds
      expect-equals 1 remaining.size
      expect-equals 1 (remaining[0] as BondInfo).slot
      // A previously returned inventory is data, not a live view or authority.
      expect-equals 2 inventory.size
      expect-equals 0 (inventory[0] as BondInfo).slot
  finally:
    client.close

class RawClient extends clients.Client:
  constructor --provider-pid/int?=null: super --provider-pid=provider-pid
  raw index/int payload/any -> any: return invoke_ index payload

class Provider extends providers.Provider:
  release/monitor.Latch ::= monitor.Latch
  constructor registry/bond-registry.Registry gid/int:
    super registry --administrator-gid=gid
  handle index/int arguments/any --gid/int --client/int -> any:
    // Test-only barrier; the production API has no such operation.
    if index == 1000:
      release.get
      return null
    return super index arguments --gid=gid --client=client

class Records extends fixture.MemoryRecords:
  operations/int := 0
  constructor: super {:}
  read name/string -> ByteArray?:
    operations++
    return super name
  write name/string bytes/ByteArray -> none:
    operations++
    super name bytes
  remove name/string -> none:
    operations++
    super name
