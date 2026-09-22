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
import ble.experimental.security-owner show Owner
import ble.experimental.service.api as api
import ble.experimental.service.gatt-provider as service
import ble.experimental.service.provider as rpc
import ble.experimental.transport
import system
import .vhci-cccd-provider as previous

DATABASE-ID ::= #[1, 2, 4]
PENDING ::= #[0x81, 3, 9, 0, 2, 0, 16, 0, 1, 0, 19, 0, 2, 0]

// Uses the existing public fixture keys/bond namespace from service-cccd.
// This image is installed without a boot trigger and never pairs a fresh peer.
main arguments/List:
  stage/string := arguments[0]
  cycle/int := arguments[1]
  if not ["migrate", "confirm"].contains stage: throw "INVALID_ARGUMENT"
  with-timeout --ms=60_000:
    table := bond-table.Table (bond-flash.FlashRecords "$(previous.PATH)/bonds")
        (ByteArray 32 --initial=42)
        --capacity=1
    records := bond-flash.FlashRecords "$(previous.PATH)/cccd"
    bank := cccd-storage.Storage records (ByteArray 32 --initial=43)
    registry := bond-registry.Registry table --cccd-storage=bank
    database := Database
    migration := attributes.ConfigurationMigration previous.Database database {13: 16, 16: 19}
    provider := Provider registry database stage cycle
    try:
      if table.occupied != [0]: throw "CCCD_MIGRATE_BOND_MISSING"
      candidate := table.load 0
      original := candidate.encode
      raw-before := records.read "cccd/0"
      if stage == "migrate":
        old := (bank.session 0 candidate --database-id=previous.DATABASE-ID).load
        if old != #[1, 3, 9, 0, 2, 0, 13, 0, 1, 0, 16, 0, 2, 0]:
          throw "CCCD_MIGRATE_OLD_STATE"
      else:
        expected := PENDING.copy
        if cycle > 0: expected[0] = 1
        if (bank.session 0 candidate --database-id=DATABASE-ID).load != expected:
          throw "CCCD_MIGRATE_RESUME_STATE"
      migrated := 0
      registry.migrate-cccd --from-id=previous.DATABASE-ID --to-id=DATABASE-ID: | state |
        migrated++
        migration.apply state
      if migrated != (stage == "migrate" ? 1 : 0): throw "CCCD_MIGRATE_TRANSFORM_COUNT"
      if stage == "confirm" and (records.read "cccd/0") != raw-before:
        throw "CCCD_MIGRATE_REWROTE_ON_RESTART"
      before := system.process-stats --gc
      provider.install
      provider.uninstall --wait
      if not provider.secured or provider.selected != 1 or
          provider.notifications != (stage == "migrate" ? 1 : 20):
        throw "CCCD_MIGRATE_PROVIDER_COUNTS"
      if (table.load 0).encode != original: throw "CCCD_MIGRATE_BOND_CHANGED"
      expected := PENDING.copy
      if stage == "confirm": expected[0] = 1
      if (bank.session 0 candidate --database-id=DATABASE-ID).load != expected:
        throw "CCCD_MIGRATE_FINAL_STATE"
      if stage == "confirm" and cycle > 0 and (records.read "cccd/0") != raw-before:
        throw "CCCD_MIGRATE_REPEATED_CLEAR"
      after := system.process-stats --gc
      gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if gcs < (stage == "migrate" ? 1 : 20): throw "CCCD_MIGRATE_PROVIDER_GC"
      print "CCCD_MIGRATE_PROVIDER COMPLETE stage=$stage cycle=$cycle migrated=$migrated pending=$(stage == "migrate") full-gcs=$gcs bond-retained=true"
    finally:
      provider.uninstall
      registry.close

class Provider extends service.Provider:
  registry_/bond-registry.Registry
  database_/attributes.Database
  stage_/string
  cycle_/int
  secured/bool := false
  selected/int := 0
  notifications/int := 0

  constructor .registry_ .database_ .stage_ .cycle_: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
  receive-acl-packets -> int: return 4
  create-database -> attributes.Database: return database_
  advertisement -> ByteArray: return #[2, 1, 6, 3, 3, 0xf0, 0xff]
  create-builder client/int name/string -> rpc.Session: throw "CCCD_MIGRATE_FIXED_DATABASE"
  create-bounded-builder client/int name/string value-limit/int mtu-limit/int -> rpc.Session:
    throw "CCCD_MIGRATE_FIXED_DATABASE"

  create-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    print "CCCD_MIGRATE READY stage=$stage_ cycle=$cycle_"
    return previous.Host controller info receive-limit registry_ --resumed

  create-security-owner host/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    if link.info.address != previous.PEER or link.info.address-type != 0:
      throw "CCCD_MIGRATE_WRONG_PEER"
    return (host as previous.Host).owner

  create-cccd-store host/central.Central link/central.Link database/attributes.Database owner/Owner? -> cccd.Store?:
    if database != database_: throw "CCCD_MIGRATE_FIXED_DATABASE"
    selected++
    return registry_.cccd-store owner --database-id=DATABASE-ID

  run-security-owner owner/Owner -> none:
    (owner as bond-resume.Resume).run
    if not owner.encrypted or not owner.authenticated: throw "CCCD_MIGRATE_SECURITY"
    secured = true

  handle index/int arguments/any --gid/int --client/int -> any:
    result := super index arguments --gid=gid --client=client
    if index == api.NOTIFY:
      notifications++
      system.process-stats --gc
    return result

class Database extends attributes.Database:
  constructor:
    super.with-defaults --name="Toit CCCD migration"
    add-service #[0xf0, 0xff]
    decoy := add-characteristic #[0xf4, 0xff] --read --notify --authenticated --value=#[99]
    notified := add-characteristic #[0xf1, 0xff] --read --notify --authenticated --value=#[0, 0, 42]
    indicated := add-characteristic #[0xf2, 0xff] --read --indicate --authenticated --value=#[0, 0, 43]
    control := add-characteristic #[0xf3, 0xff] --write --authenticated --value=#[0]
    if service-changed-handle != 8 or decoy != 12 or notified != 15 or indicated != 18 or control != 21:
      throw "CCCD_MIGRATE_LAYOUT_CHANGED"
