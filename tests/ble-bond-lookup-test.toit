// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.privacy
import ble.experimental.smp-identity show Identity
import expect show *
import system
import .ble-bond-table-test as fixture

main:
  local := Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  other-local := Identity (ByteArray 16 --initial=2) #[2, 3, 4, 5, 6, 0xc1] 1
  peer := Identity (ByteArray 16 --initial=3) #[3, 4, 5, 6, 7, 8] 0
  other-peer := Identity (ByteArray 16 --initial=4) #[4, 5, 6, 7, 8, 0xc2] 1
  first := bond.Candidate (ByteArray 16 --initial=1) local peer --authenticated
  second := bond.Candidate (ByteArray 16 --initial=2) local other-peer --no-authenticated
  third := bond.Candidate (ByteArray 16 --initial=3) other-local peer --authenticated
  backend := fixture.MemoryRecords {:}
  table := bond-table.Table backend (ByteArray 32 --initial=42) --capacity=4
  expect-null (find table.snapshot local peer false)
  expect-equals 0 (table.add first)
  expect-equals 1 (table.add second)
  expect-equals 2 (table.add third)
  snapshot := table.snapshot
  [false, true].do: | private/bool |
    [first, second, third].do: | candidate/bond.Candidate |
      entry := find snapshot candidate.local candidate.peer private
      expect-equals candidate.encode entry.candidate.encode
    expect-equals 0 (find snapshot local peer private).slot
    expect-equals 1 (find snapshot local other-peer private).slot
    expect-equals 2 (find snapshot other-local peer private).slot
    expect-null (find snapshot other-local other-peer private)
  // Shared IRKs can make RPA resolution ambiguous even with distinct identities.
  duplicate-peer := Identity peer.irk #[5, 6, 7, 8, 9, 10] 0
  duplicate := bond.Candidate (ByteArray 16 --initial=9) local duplicate-peer --no-authenticated
  table.add duplicate
  expect-throw "BLE_STALE_BOND_SNAPSHOT": find snapshot local peer false
  expect-throw "BLE_AMBIGUOUS_BOND": find table.snapshot local peer true
  expect-equals 0 (find table.snapshot local peer false).slot
  expect-equals 3 (find table.snapshot local duplicate-peer false).slot
  // Even identical candidate bytes in two slots require an explicit policy choice.
  table.save 3 first
  expect-throw "BLE_AMBIGUOUS_BOND": find table.snapshot local peer false
  expect-throw "BLE_STALE_BOND_SNAPSHOT": find snapshot local peer false
  table.remove 3
  table.remove 0
  expect-null (find table.snapshot local peer false)
  // Mutations invalidate old lookups, including after compacting GC.
  system.process-stats --gc
  expect-throw "BLE_STALE_BOND_SNAPSHOT": find snapshot local peer true
  snapshot = table.snapshot
  expect-equals second.encode (find snapshot local other-peer true).candidate.encode
  backend.entries.values.do: | bytes/ByteArray | bytes.fill 0
  expect-throw "BLE_INVALID_SEALED_BOND": table.snapshot
  table.close
  expect-throw "BLE_BOND_STORAGE_CLOSED": table.snapshot
  expect-throw "BLE_STALE_BOND_SNAPSHOT": find snapshot local other-peer true
  expect-throw "INVALID_ARGUMENT": snapshot.find
      --local-address=#[]
      --local-address-type=0
      --peer-address=peer.address
      --peer-address-type=0
  expect-throw "INVALID_ARGUMENT": snapshot.find
      --local-address=local.address
      --local-address-type=0
      --peer-address=peer.address
      --peer-address-type=2
  expect-throw "INVALID_ARGUMENT": local.matches #[] --address-type=0
  expect-throw "INVALID_ARGUMENT": local.matches local.address --address-type=4
  expect (not (local.matches local.address --address-type=2))
  // A zero IRK does not acquire private-address resolution capability.
  zero := Identity (ByteArray 16) local.address 0
  expect (not (zero.matches (privacy.from-prand zero.irk #[0x41, 2, 3]) --address-type=1))

find snapshot/bond-table.Snapshot local/Identity peer/Identity private/bool -> bond-table.Entry?:
  local-address := private ? (privacy.from-prand local.irk #[0x41, 2, 3]) : local.address
  peer-address := private ? (privacy.from-prand peer.irk #[0x42, 3, 4]) : peer.address
  result := snapshot.find
      --local-address=local-address
      --local-address-type=(private ? 1 : local.address-type)
      --peer-address=peer-address
      --peer-address-type=(private ? 1 : peer.address-type)
  local-address.fill 0
  peer-address.fill 0
  return result
