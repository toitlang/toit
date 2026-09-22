// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.bond-flash
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.bond-table
import ble.experimental.cccd-storage
import ble.experimental.cccd-store as cccd
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import ble.experimental.service.api as api
import ble.experimental.service.gatt-provider as service
import ble.experimental.service.provider as rpc
import ble.experimental.transport
import system

PATH ::= "toit.test/cccd-service-v1"
DATABASE-ID ::= #[1, 2, 3]
PEER ::= #[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a]

// This fixture image is installed without a boot trigger. The supervisor passes
// explicit resumption, cycle and phase arguments; missing storage never re-pairs.
main arguments/List:
  resumed/bool := arguments[0]
  cycle/int := arguments[1]
  phase/string := arguments[2]
  with-timeout --ms=60_000:
    // Public fixture keys stay in the provider image, never the application.
    table := bond-table.Table (bond-flash.FlashRecords "$PATH/bonds")
        (ByteArray 32 --initial=42)
        --capacity=1
    records := bond-flash.FlashRecords "$PATH/cccd"
    bank := cccd-storage.Storage records (ByteArray 32 --initial=43)
    registry := bond-registry.Registry table --cccd-storage=bank
    provider := Provider registry --resumed=resumed --cycle=cycle --phase=phase
    try:
      if table.occupied != (resumed ? [0] : []): throw "CCCD_SERVICE_WRONG_PHASE"
      original := resumed ? (table.load 0).encode : null
      configuration := records.read "cccd/0"
      if (configuration != null) != resumed: throw "CCCD_SERVICE_CONFIGURATION_PHASE"
      before := system.process-stats --gc
      provider.install
      provider.uninstall --wait
      if not provider.secured or provider.selected != 1 or provider.notifications != 20:
        throw "CCCD_SERVICE_PROVIDER_COUNTS"
      saved := table.load 0
      if not saved or not saved.authenticated: throw "CCCD_SERVICE_BOND_MISSING"
      if original and saved.encode != original: throw "CCCD_SERVICE_BOND_CHANGED"
      if configuration and (records.read "cccd/0") != configuration:
        throw "CCCD_SERVICE_CONFIGURATION_REWRITTEN"
      state := (bank.session 0 saved --database-id=DATABASE-ID).load
      if state != #[1, 3, 9, 0, 2, 0, 13, 0, 1, 0, 16, 0, 2, 0]:
        throw "CCCD_SERVICE_CONFIGURATION_MISMATCH"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < 20: throw "CCCD_SERVICE_PROVIDER_GC"
      print "CCCD_SERVICE_PROVIDER COMPLETE cycle=$cycle resumed=$resumed pid=$(Process.current.id) selections=1 notifications=20 full-gcs=$gcs stored=true"
    finally:
      provider.uninstall
      registry.close

class Provider extends service.Provider:
  registry_/bond-registry.Registry
  resumed_/bool
  cycle_/int
  phase_/string
  secured/bool := false
  selected/int := 0
  notifications/int := 0

  constructor .registry_ --resumed/bool --cycle/int --phase/string:
    resumed_ = resumed
    cycle_ = cycle
    phase_ = phase
    super

  open-transport -> transport.Transport: return esp32.Esp32Transport
  receive-acl-packets -> int: return 4

  create-database -> attributes.Database: return Database
  advertisement -> ByteArray: return #[2, 1, 6, 3, 3, 0xf0, 0xff]

  // This provider's persistent revision describes its own fixed schema. An
  // arbitrary application builder must not inherit that revision or its CCCDs.
  create-builder client/int name/string -> rpc.Session:
    throw "CCCD_SERVICE_FIXED_DATABASE"
  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> rpc.Session:
    throw "CCCD_SERVICE_FIXED_DATABASE"

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    print "CCCD_PERSIST READY phase=$phase_ cycle=$cycle_ resumed=$resumed_"
    return Host controller info receive-limit registry_ --resumed=resumed_

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    if link.info.address != PEER or link.info.address-type != 0: throw "CCCD_SERVICE_WRONG_PEER"
    if resumed_: return (host as Host).owner
    pairing := security.Pairing host link --local-address=info.address
        --io-capability=1
        --require-authentication
        --bond
        --attempts=pairing-attempts
        --attempt-identity=(pairing-peer-identity link)
    return registry_.bond host link pairing --local-address=info.address

  create-cccd-store host/central.Central link/central.Link database/attributes.Database owner/Owner? -> cccd.Store?:
    if not (database is Database): throw "CCCD_SERVICE_FIXED_DATABASE"
    selected++
    return registry_.cccd-store owner --database-id=DATABASE-ID

  run-security-owner owner/Owner -> none:
    if resumed_:
      (owner as bond-resume.Resume).run
    else:
      (owner as bond-registry.Bonding).run: | number/int |
        print "CCCD_PERSIST NUMERIC value=$number fixture-approval=true"
        true
    if not owner.encrypted or not owner.authenticated: throw "CCCD_SERVICE_SECURITY"
    secured = true
    print "CCCD_PERSIST SECURE cycle=$cycle_ resumed=$resumed_ authenticated=true"

  handle index/int arguments/any --gid/int --client/int -> any:
    result := super index arguments --gid=gid --client=client
    if index == api.NOTIFY:
      notifications++
      system.process-stats --gc
    return result

class Host extends central.Central:
  registry_/bond-registry.Registry
  local_/ByteArray
  resumed_/bool
  owner/bond-resume.Resume? := null
  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .registry_ --resumed/bool:
    local_ = info.address.copy
    resumed_ = resumed
    super controller --acl-length=info.acl-length --acl-count=info.acl-count --receive-limit=receive-limit
  on-connected link/central.Link -> none:
    if resumed_:
      owner = registry_.resume this link --local-address=(link.local-random-address or local_) --require-authentication

class Database extends attributes.Database:
  constructor:
    super.with-defaults --name="Toit CCCD service"
    add-service #[0xf0, 0xff]
    notified := add-characteristic #[0xf1, 0xff] --read --notify --authenticated --value=#[0, 0, 42]
    indicated := add-characteristic #[0xf2, 0xff] --read --indicate --authenticated --value=#[0, 0, 43]
    control := add-characteristic #[0xf3, 0xff] --write --authenticated --value=#[0]
    if service-changed-handle != 8 or notified != 12 or indicated != 15 or control != 18:
      throw "CCCD_SERVICE_LAYOUT_CHANGED"
