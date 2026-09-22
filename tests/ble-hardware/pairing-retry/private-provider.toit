// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.smp-identity show Identity
import encoding.hex
import system
import .provider as fixture
import ...ble-bond-table-test as storage

// Public fixture identity/IRK, not production provisioning material.
main:
  run (Identity (ByteArray 16: it + 1) #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a] 0)

run identity/Identity:
  provider := Provider identity
  provider.install
  try:
    provider.uninstall --wait
    if provider.confirmations != 2: throw "WRONG_CONFIRMATION_COUNT"
    print "RETRY_PROVIDER COMPLETE confirmations=2"
  finally:
    provider.uninstall
    provider.close-registry

class Provider extends fixture.Provider:
  identity_/Identity
  local_/ByteArray? := null
  registry_/bond-registry.Registry? := null
  constructor .identity_: super

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if not registry_:
      local_ = info.address.copy
      table := bond-table.Table (storage.MemoryRecords {:}) (ByteArray 32 --initial=42) --capacity=1
      registry_ = bond-registry.Registry table
      // Seed only resolution metadata. This placeholder LTK is never resumed;
      // each connection explicitly exercises fresh fixture-controlled pairing.
      candidate := bond.Candidate (ByteArray 16 --initial=9)
          (Identity (ByteArray 16) local_ 0)
          identity_
          --no-authenticated
      registry_.add candidate
    return super controller info receive-limit

  pairing-peer-identity link/central.Link -> ByteArray:
    if link.info.address-type != 1 or link.info.address[5] & 0xc0 != 0x40:
      throw "EXPECTED_PRIVATE_PEER"
    result := registry_.resolve-peer-identity --local-address=local_ --local-address-type=0
        --peer-address=link.info.address
        --peer-address-type=link.info.address-type
    if result != (#[identity_.address-type] + identity_.address): throw "WRONG_RETRY_IDENTITY"
    system.process-stats --gc
    print "RETRY_PROVIDER IDENTITY round=$round peer=$(hex.encode link.info.address.reverse) stable=$(hex.encode result)"
    return result

  close-registry -> none:
    if registry_: registry_.close
