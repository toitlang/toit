// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-flash
import ble.experimental.bond-registry
import ble.experimental.bond-table
import ble.experimental.central
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.smp-identity show Identity
import ble.experimental.cccd-storage
import crypto
import encoding.hex
import system
import .vhci-cccd-provider as previous

PATH ::= "toit.test/cccd-private-v2"

// The ordinary CCCD service supervisor/application select this provider image.
// Fresh pairing uses public identities; every resumption uses two fresh RPAs.
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
      if table.occupied != (resumed ? [0] : []): throw "CCCD_PRIVATE_WRONG_PHASE"
      saved := resumed ? table.load 0 : null
      original := saved ? saved.encode : null
      configuration := records.read "cccd/0"
      if (configuration != null) != resumed: throw "CCCD_PRIVATE_CONFIGURATION_PHASE"
      provider = Provider registry saved --resumed=resumed --cycle=cycle --phase=phase
      before := system.process-stats --gc
      provider.install
      provider.uninstall --wait
      if not provider.secured or provider.selected != 1 or provider.notifications != 20:
        throw "CCCD_PRIVATE_PROVIDER_COUNTS"
      saved = table.load 0
      if not saved or not saved.authenticated or not saved.local.has-resolving-key or not saved.peer.has-resolving-key:
        throw "CCCD_PRIVATE_BOND_MISSING"
      if saved.peer.address != previous.PEER or saved.peer.address-type != 0:
        throw "CCCD_PRIVATE_IDENTITY_CHANGED"
      if original and saved.encode != original: throw "CCCD_PRIVATE_BOND_CHANGED"
      if configuration and (records.read "cccd/0") != configuration:
        throw "CCCD_PRIVATE_CONFIGURATION_REWRITTEN"
      if (bank.session 0 saved --database-id=previous.DATABASE-ID).load !=
          #[1, 3, 9, 0, 2, 0, 13, 0, 1, 0, 16, 0, 2, 0]:
        throw "CCCD_PRIVATE_CONFIGURATION_MISMATCH"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < 20: throw "CCCD_PRIVATE_PROVIDER_GC"
      print "CCCD_SERVICE_PROVIDER COMPLETE cycle=$cycle resumed=$resumed pid=$(Process.current.id) selections=1 notifications=20 full-gcs=$gcs stored=true"
      print "CCCD_PRIVATE COMPLETE cycle=$cycle resumed=$resumed identities-retained=true"
    finally:
      if provider: provider.uninstall
      registry.close

class Provider extends previous.Provider:
  registry_/bond-registry.Registry
  resumed_/bool
  cycle_/int
  local_/ByteArray?
  peer_/ByteArray? := null

  constructor .registry_ saved/bond.Candidate? --resumed/bool --cycle/int --phase/string:
    resumed_ = resumed
    cycle_ = cycle
    local_ = saved ? privacy.generate saved.local.irk : null
    super registry_ --resumed=resumed --cycle=cycle --phase=phase

  local-random-address -> ByteArray?: return local_

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    if local_: print "CCCD_PRIVATE LOCAL cycle=$cycle_ address=$(hex.encode local_.reverse)"
    return super controller info receive-limit

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    if resumed_:
      if not local_ or link.local-random-address != local_ or link.info.address-type != 1:
        throw "CCCD_PRIVATE_PUBLIC_RESUMPTION"
      identity := registry_.resolve-peer-identity --local-address=local_
          --local-address-type=1
          --peer-address=link.info.address
          --peer-address-type=link.info.address-type
      if identity != #[0] + previous.PEER: throw "CCCD_PRIVATE_WRONG_RESOLVED_PEER"
      peer_ = link.info.address.copy
      return (host as previous.Host).owner
    if link.info.address != previous.PEER or link.info.address-type != 0:
      throw "CCCD_PRIVATE_WRONG_PAIRING_PEER"
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

  run-security-owner owner/Owner -> none:
    super owner
    if resumed_:
      print "CCCD_PRIVATE CONNECTED cycle=$cycle_ local=$(hex.encode local_.reverse) peer=$(hex.encode peer_.reverse) resolved=true"
