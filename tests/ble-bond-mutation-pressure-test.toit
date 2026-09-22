// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.smp-identity show Identity
import expect show *
import system
import .ble-bond-admin-test as fixture

main:
  slots := List 16384
  key := ByteArray 32 --initial=42
  identity := Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  candidate := bond.Candidate (ByteArray 16 --initial=9) identity identity --authenticated
  set-max-heap-size_ (256 * 1024)
  quarantined := 0
  unchanged := 0
  succeeded := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      records := fixture.Records
      registry := bond-registry.Registry (bond-table.Table records key --capacity=2)
      revision := registry.inventory[0]
      try:
        filled := 0
        exhaustion := catch:
          while filled < slots.size:
            slots[filled] = ByteArray 8
            filled++
        if exhaustion != "OUT_OF_MEMORY" and exhaustion != "ALLOCATION_FAILED":
          throw "PRESSURE_NOT_REACHED"
        (trial * 32).repeat: slots[filled - 1 - it] = null
        slot := -1
        error := catch: slot = registry.add candidate
        slots.fill null
        system.process-stats --gc
        inventory := null
        inventory-error := catch: inventory = registry.inventory
        if error:
          if error != "OUT_OF_MEMORY" and error != "ALLOCATION_FAILED": throw error
          if inventory-error:
            expect-equals "BLE_BOND_REGISTRY_FAILED" inventory-error
            before := records.operations
            expect-throw "BLE_BOND_REGISTRY_FAILED": registry.add candidate
            expect-throw "BLE_BOND_REGISTRY_FAILED": registry.remove 0
            expect-equals before records.operations
            quarantined++
          else:
            expect-equals revision inventory[0]
            expect-equals [] inventory[1]
            expect records.entries.is-empty
            expect-equals 0 (registry.add candidate)
            unchanged++
        else:
          expect-null inventory-error
          expect-equals 0 slot
          expect (inventory[0] != revision)
          expect-equals 1 inventory[1].size
          succeeded++
      finally:
        slots.fill null
        registry.close
      expect records.closed
    expect (quarantined > 0 and unchanged > 0 and succeeded > 0)
    print "BOND_MUTATION_PRESSURE COMPLETE quarantined=$quarantined unchanged=$unchanged succeeded=$succeeded"
