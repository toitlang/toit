// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system
import system.services
import ble.experimental.bond
import ble.experimental.bond-info show BondInfo
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.privacy
import ble.experimental.pairing-attempts as retry
import ble.experimental.smp-identity show Identity
import ble.experimental.service.bond-admin-api as api
import ble.experimental.service.bond-admin-client as clients
import .ble-bond-admin-test as fixture

main:
  with-timeout --ms=10_000:
    snapshots
    resolved-retry-identity
    mutation-wait
    stale-removal
    full-table-noop
    malformed-replies

class PausedRecords extends fixture.Records:
  writing/monitor.Latch ::= monitor.Latch
  proceed/monitor.Latch ::= monitor.Latch
  write name/string bytes/ByteArray -> none:
    writing.set true
    proceed.get
    super name bytes

mutation-wait:
  records := PausedRecords
  registry := bond-registry.Registry (bond-table.Table records (ByteArray 32 --initial=42) --capacity=2)
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate (ByteArray 16 --initial=9) identity identity --authenticated
  revision/ByteArray := registry.inventory[0]
  ended := monitor.Latch
  remove-started := monitor.Latch
  remove-ended := monitor.Latch
  remover/Task? := null
  remove-error := null
  failure := null
  writer := task::
    try:
      failure = catch: registry.add candidate
    finally:
      critical-do --no-respect-deadline: ended.set true
  try:
    records.writing.get
    expect-throw "BLE_BOND_ADMISSION_PAUSED":
      registry.resolve-peer-identity --local-address=identity.address --local-address-type=0
          --peer-address=identity.address
          --peer-address-type=0
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=20: registry.bonds
    remover = task::
      try:
        remove-started.set true
        remove-error = catch: registry.remove 0 --if-revision=revision
      finally:
        critical-do --no-respect-deadline: remove-ended.set true
    remove-started.get
    expect (not remove-ended.has-value)
    records.proceed.set true
    ended.get
    remove-ended.get
    expect-equals null failure
    expect-equals "BLE_STALE_BOND_INVENTORY" remove-error
    before := records.operations
    result := registry.bonds
    expect-equals before records.operations
    expect-equals 1 result.size
    expect-equals 0 (result[0] as BondInfo).slot
    expect (result[0] as BondInfo).authenticated
  finally:
    writer.cancel
    if remover: remover.cancel
    critical-do --no-respect-deadline:
      records.proceed.set true
      ended.get
      if remover: remove-ended.get
      registry.close

snapshots:
  records := fixture.Records
  table := bond-table.Table records (ByteArray 32 --initial=42) --capacity=2
  registry := bond-registry.Registry table
  try:
    expect-equals [] registry.bonds
    local := Identity (ByteArray 16 --initial=7) #[1, 2, 3, 4, 5, 6] 0
    peer := Identity (ByteArray 16 --initial=8) #[6, 5, 4, 3, 2, 0xc1] 1
    candidate := bond.Candidate (ByteArray 16 --initial=9) local peer --no-authenticated
    registry.add candidate
    before := records.operations
    inventory := registry.bonds
    expect-equals before records.operations
    info/BondInfo := inventory[0]
    expect-equals 0 info.slot
    expect-equals 1 info.peer-address-type
    expect (not info.authenticated)
    expect-equals peer.address info.peer-address
    snapshot := table.snapshot
    registry.remove 0
    expect-throw "BLE_STALE_BOND_SNAPSHOT": snapshot.bonds
    system.process-stats --gc
    expect-equals peer.address info.peer-address
    info.peer-address.fill 0
    expect-equals peer.address info.peer-address
    expect-equals [] registry.bonds
    registry.close
    expect-throw "BLE_BOND_REGISTRY_CLOSED": registry.bonds
  finally:
    registry.close

row slot/int=0 -> List:
  return [slot, #[1, 2, 3, 4, 5, 6], 0, #[6, 5, 4, 3, 2, 1], 0, true]

malformed-replies:
  provider := Provider
  provider.install
  client := clients.Client --provider-pid=Process.current.id
  client.open
  try:
    provider.response = []
    expect-equals [] client.bonds
    provider.response = [row]
    expect-equals 0 ((client.bonds)[0] as BondInfo).slot
    [null, 0, [null], [#[]], [row, row], [row 1, row 0], [row -1], [row 255],
      [((row) + [99])], (List 256)].do: | response/any |
      provider.response = response
      expect-throw "BLE_BOND_ADMIN_BAD_RESPONSE": client.bonds
    ["0", (ByteArray 5), 2, (ByteArray 7), -1, 1].size.repeat: | index/int |
      changed := row
      changed[index] = ["0", (ByteArray 5), 2, (ByteArray 7), -1, 1][index]
      provider.response = [changed]
      expect-throw "BLE_BOND_ADMIN_BAD_RESPONSE": client.bonds
    provider.wrapped = false
    [null, [], [#[], []], [(ByteArray 16)], [(ByteArray 16), [], 0],
      [(ByteArray 15), []], ["nonce", []]].do: | response/any |
      provider.response = response
      expect-throw "BLE_BOND_ADMIN_BAD_RESPONSE": client.bonds
  finally:
    client.close
    provider.uninstall

// A test provider supplies malformed wire values; discovery is not validation.
class Provider extends services.ServiceProvider implements services.ServiceHandler:
  response/any := null
  wrapped/bool := true
  constructor:
    super "bond-inventory-fixture" --major=0 --minor=3
    provides api.SELECTOR --handler=this
  handle index/int arguments/any --gid/int --client/int -> any:
    expect-equals api.BONDS-WITH-REVISION index
    expect-equals null arguments
    return wrapped ? [(ByteArray 16 --initial=42), response] : response

stale-removal:
  records := fixture.Records
  table := bond-table.Table records (ByteArray 32 --initial=42) --capacity=2
  registry := bond-registry.Registry table
  other := bond-registry.Registry (bond-table.Table (fixture.Records) (ByteArray 32 --initial=43) --capacity=2)
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate (ByteArray 16 --initial=9) identity identity --authenticated
  try:
    registry.add candidate
    revision/ByteArray := registry.inventory[0]
    registry.remove 0
    replacement := bond.Candidate (ByteArray 16 --initial=10) identity identity --authenticated
    expect-equals 0 (registry.add replacement)
    before := records.operations
    expect-throw "BLE_STALE_BOND_INVENTORY": registry.remove 0 --if-revision=revision
    expect-equals before records.operations
    expect-equals replacement.encode (table.load 0).encode
    current/ByteArray := registry.inventory[0]
    expect-throw "BLE_STALE_BOND_INVENTORY": other.remove 0 --if-revision=current
    registry.remove 0 --if-revision=current
    expect-equals [] registry.bonds
    expect-throw "BLE_STALE_BOND_INVENTORY": registry.remove 0 --if-revision=current
  finally:
    registry.close
    other.close

full-table-noop:
  registry := bond-registry.Registry (bond-table.Table (fixture.Records) (ByteArray 32 --initial=42) --capacity=1)
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate (ByteArray 16 --initial=9) identity identity --authenticated
  try:
    registry.add candidate
    revision/ByteArray := registry.inventory[0]
    expect-throw "BLE_BOND_TABLE_FULL": registry.add candidate
    expect-equals revision registry.inventory[0]
    registry.remove 0 --if-revision=revision
    expect-equals [] registry.bonds
  finally:
    registry.close

resolved-retry-identity:
  records := fixture.Records
  registry := bond-registry.Registry (bond-table.Table records (ByteArray 32 --initial=42) --capacity=2)
  local := Identity (ByteArray 16 --initial=7) #[1, 2, 3, 4, 5, 6] 0
  peer := Identity (ByteArray 16 --initial=8) #[6, 5, 4, 3, 2, 0xc1] 1
  candidate := bond.Candidate (ByteArray 16 --initial=9) local peer --authenticated
  first := privacy.from-prand peer.irk #[0x41, 2, 3]
  second := privacy.from-prand peer.irk #[0x42, 2, 3]
  attempts := retry.Attempts --minimum=(Duration --s=10)
  try:
    registry.add candidate
    before := records.operations
    identity := resolve registry local.address first
    expect-equals (#[1] + peer.address) identity
    expect-equals null (resolve registry #[9, 8, 7, 6, 5, 4] first)
    expect-throw "FAILED_PAIRING":
      attempts.with-attempt identity: throw "FAILED_PAIRING"
    identity.fill 0
    system.process-stats --gc
    expect-throw "SMP_REPEATED_ATTEMPTS":
      attempts.with-attempt (resolve registry local.address second): unreachable
    expect-equals before records.operations
    // Resolution must retain the snapshot's ambiguity rule, not choose a key.
    registry.add candidate
    expect-throw "BLE_AMBIGUOUS_BOND": resolve registry local.address second
    registry.remove 1
    registry.remove 0
    expect-equals null (resolve registry local.address second)
    registry.close
    expect-throw "BLE_BOND_REGISTRY_CLOSED": resolve registry local.address second
  finally:
    registry.close

resolve registry/bond-registry.Registry local/ByteArray peer/ByteArray -> ByteArray?:
  return registry.resolve-peer-identity --local-address=local --local-address-type=0
      --peer-address=peer
      --peer-address-type=1
