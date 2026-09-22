// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond-flash
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.cccd-storage
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity show Identity
import crypto
import system
import .vhci-cccd-provider as previous

PATH ::= "toit.test/cccd-android-v1"

// Dedicated isolated phone fixture: the operator matches the displayed Numeric
// Comparison value with the phone's system pairing dialog before approving it.
// The first authenticated peer occupies the only slot. Resumption never pairs.
main arguments/List:
  resumed/bool := arguments[0]
  cycle/int := arguments[1]
  phase/string := arguments[2]
  with-timeout --ms=60_000:
    table := bond-table.Table (bond-flash.FlashRecords "$PATH/bonds")
        (ByteArray 32 --initial=42)
        --capacity=1
    records := bond-flash.FlashRecords "$PATH/cccd"
    bank := cccd-storage.Storage records (ByteArray 32 --initial=43)
    registry := bond-registry.Registry table --cccd-storage=bank
    provider/Provider? := null
    try:
      if table.occupied != (resumed ? [0] : []): throw "CCCD_ANDROID_WRONG_PHASE"
      original := resumed ? (table.load 0).encode : null
      configuration := records.read "cccd/0"
      if (configuration != null) != resumed: throw "CCCD_ANDROID_CONFIGURATION_PHASE"
      provider = Provider registry --resumed=resumed --cycle=cycle --phase=phase
      before := system.process-stats --gc
      provider.install
      provider.uninstall --wait
      if not provider.secured or provider.selected != 1 or provider.notifications != 20:
        throw "CCCD_ANDROID_PROVIDER_COUNTS"
      saved := table.load 0
      if not saved or not saved.authenticated or not saved.peer.has-resolving-key:
        throw "CCCD_ANDROID_BOND_MISSING"
      if original and saved.encode != original: throw "CCCD_ANDROID_BOND_CHANGED"
      if configuration and (records.read "cccd/0") != configuration:
        throw "CCCD_ANDROID_CONFIGURATION_REWRITTEN"
      if (bank.session 0 saved --database-id=previous.DATABASE-ID).load !=
          #[1, 3, 9, 0, 2, 0, 13, 0, 1, 0, 16, 0, 2, 0]:
        throw "CCCD_ANDROID_CONFIGURATION_MISMATCH"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < 20: throw "CCCD_ANDROID_PROVIDER_GC"
      print "CCCD_ANDROID_PROVIDER COMPLETE cycle=$cycle resumed=$resumed full-gcs=$gcs authenticated=true identity-retained=true configuration-retained=true"
    finally:
      if provider: provider.uninstall
      registry.close

class Provider extends previous.Provider:
  registry_/bond-registry.Registry
  resumed_/bool

  constructor .registry_ --resumed/bool --cycle/int --phase/string:
    resumed_ = resumed
    super registry_ --resumed=resumed --cycle=cycle --phase=phase

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    if resumed_: return (host as previous.Host).owner
    identity := Identity (crypto.random --size=16) info.address 0
    pairing := security.Pairing host link --local-address=info.address
        --io-capability=1
        --require-authentication
        --bond
        --identity=identity
        --request-identity
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
    return registry_.bond host link pairing --local-address=info.address
