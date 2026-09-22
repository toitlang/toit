// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.bond-flash
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.bond-table
import ble.experimental.cccd-storage
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.security
import ble.experimental.security-owner show Owner
import monitor
import system

// Explicit test namespace and public fixture keys. Never infer fresh pairing
// from missing storage in the resume phase, or erase an existing fixture bond.
run --resume/bool --storage-path/string --peer-address/ByteArray:
  with-timeout --ms=120_000:
    table := bond-table.Table (bond-flash.FlashRecords "$storage-path/bonds")
        (ByteArray 32 --initial=42)
        --capacity=1
    records := bond-flash.FlashRecords "$storage-path/cccd"
    bank := cccd-storage.Storage records (ByteArray 32 --initial=43)
    registry := bond-registry.Registry table --cccd-storage=bank
    controller := hci.Controller (esp32.Esp32Transport)
    host/Host? := null
    try:
      if table.occupied != (resume ? [0] : []): throw "CCCD_PERSIST_WRONG_PHASE"
      original := resume ? (table.load 0).encode : null
      configuration := resume ? (records.read "cccd/0") : null
      if resume and not configuration: throw "CCCD_PERSIST_MISSING_CONFIGURATION"
      info := hci.initialize controller --receive-acl-packets=4
      host = Host controller info registry --resume=resume
      2.repeat: | cycle/int |
        resumed := resume or cycle > 0
        host.resuming = resumed
        database := attributes.Database.with-defaults --name="Toit CCCD persist"
        database.add-service #[0xf0, 0xff]
        notified := database.add-characteristic #[0xf1, 0xff]
            --read
            --notify
            --authenticated
            --value=#[0, 0, 42]
        indicated := database.add-characteristic #[0xf2, 0xff]
            --read
            --indicate
            --authenticated
            --value=#[0, 0, 43]
        control := database.add-characteristic #[0xf3, 0xff]
            --write
            --authenticated
            --value=#[0]
        print "CCCD_PERSIST READY phase=$(resume ? "resume" : "pair") cycle=$cycle resumed=$resumed"
        link := host.accept #[2, 1, 6, 3, 3, 0xf0, 0xff] --timeout=(Duration --s=45)
        if link.info.address != peer-address or link.info.address-type != 0:
          throw "CCCD_PERSIST_WRONG_PEER"
        owner/Owner? := host.owner
        if not resumed:
          pairing := security.Pairing host link --local-address=info.address
              --io-capability=1
              --require-authentication
              --bond
          owner = registry.bond host link pairing --local-address=info.address
        if not owner: throw "CCCD_PERSIST_MISSING_OWNER"
        store := registry.cccd-store owner --database-id=#[1, 2, 3]
        server := gatt.Server host link database --pairing=owner --cccd-store=store
        requested := monitor.Latch
        ended := monitor.Latch
        writes := 0
        worker := task::
          error := catch: server.serve: | handle/int value/ByteArray |
            if handle == control:
              if value != #[1] or requested.has-value: throw "CCCD_PERSIST_BAD_REQUEST"
              requested.set true
            else:
              if resumed: throw "CCCD_PERSIST_UNEXPECTED_REWRITE"
              if handle == notified + 1 and value == #[1, 0]: writes++
              else if handle == indicated + 1 and value == #[2, 0]: writes++
              else: throw "CCCD_PERSIST_BAD_WRITE"
          if error and not requested.has-value: requested.set error --exception
          ended.set error
        try:
          if resumed:
            (owner as bond-resume.Resume).run
          else:
            (owner as bond-registry.Bonding).run: | number/int |
              print "CCCD_PERSIST NUMERIC value=$number fixture-approval=true"
              true
          if not owner.encrypted or not owner.authenticated: throw "CCCD_PERSIST_SECURITY"
          print "CCCD_PERSIST SECURE cycle=$cycle resumed=$resumed authenticated=true"
          requested.get
          retained := #[cycle, 0, 42]
          before := system.process-stats --gc
          20.repeat: | sequence/int |
            database.set-value notified #[cycle, sequence, 42]
            database.set-value indicated #[cycle, sequence, 43]
            if not (server.notify notified): throw "CCCD_PERSIST_NOTIFICATION_DISABLED"
            receipt := server.indicate indicated --timeout=(Duration --s=3)
            if not receipt: throw "CCCD_PERSIST_INDICATION_DISABLED"
            receipt.wait
            system.process-stats --gc
          receipt := server.indicate database.service-changed-handle --timeout=(Duration --s=3)
          if not receipt: throw "CCCD_PERSIST_SERVICE_CHANGED_DISABLED"
          receipt.wait
          after := system.process-stats --gc
          gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
          if gcs < 20 or retained != #[cycle, 0, 42]: throw "CCCD_PERSIST_GC_OR_RETAINED"
          print "CCCD_PERSIST SENT cycle=$cycle indications-confirmed=21"
          error := ended.get
          if error: throw error
          if writes != (resumed ? 0 : 2): throw "CCCD_PERSIST_WRITE_COUNT"
          saved := table.load 0
          if not saved or not saved.authenticated: throw "CCCD_PERSIST_BOND_MISSING"
          if saved.peer.address != peer-address or saved.peer.address-type != 0:
            throw "CCCD_PERSIST_BOND_PEER"
          if original and saved.encode != original: throw "CCCD_PERSIST_BOND_CHANGED"
          original = saved.encode
          sealed := records.read "cccd/0"
          if not sealed: throw "CCCD_PERSIST_CONFIGURATION_MISSING"
          if configuration and sealed != configuration: throw "CCCD_PERSIST_CONFIGURATION_REWRITTEN"
          configuration = sealed
          print "CCCD_PERSIST CYCLE cycle=$cycle resumed=$resumed notifications=20 indications=20 service-changed=1 full-gcs=$gcs application-cccd-writes=$writes stored=true"
        finally:
          worker.cancel
          server.close
          owner.close
          host.owner = null
      print "CCCD_PERSIST COMPLETE phase=$(resume ? "resume" : "pair") connections=2 bonds=1 retained=true"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
      registry.close

class Host extends central.Central:
  registry_/bond-registry.Registry
  local_/ByteArray
  resuming/bool := ?
  owner/bond-resume.Resume? := null

  constructor controller/hci.Controller info/hci.Capabilities .registry_ --resume/bool:
    local_ = info.address.copy
    resuming = resume
    super controller --acl-length=info.acl-length --acl-count=info.acl-count

  on-connected link/central.Link -> none:
    if resuming:
      owner = registry_.resume this link --local-address=local_ --require-authentication
