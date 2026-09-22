// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    control-uuid := fixture.wire-uuid "9f6c4400-8e2a-4b13-9e97-94f353eeb001"
    target-uuid := fixture.wire-uuid "9f6c4300-8e2a-4b13-9e97-94f353eeb001"
    peer/service.ScanReport? := null
    client.scan --duration=(Duration --s=20) --service-uuid=control-uuid: | report/service.ScanReport |
      if report.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8] or report.address-type != 0: continue.scan true
      peer = report
      false
    if not peer: throw "REFERENCE_NOT_FOUND"
    print "BLUEZ_MIGRATION phase=connect"
    client.with-connection peer.address --address-type=peer.address-type: | connection/service.Connection |
      print "BLUEZ_MIGRATION phase=monitor"
      connection.with-service-changed:
        print "BLUEZ_MIGRATION phase=initial-discovery"
        control := find connection control-uuid
            fixture.wire-uuid "9f6c4401-8e2a-4b13-9e97-94f353eeb001"
        original := find connection target-uuid #[0xf1, 0xff]
        print "BLUEZ_MIGRATION phase=initial-read"
        before := original.read
        if before != #[7]: throw "INITIAL_VALUE_MISMATCH"
        // The control service stays fixed; its write changes a different service.
        // A stale result may mean the write already applied. Never replay it.
        print "BLUEZ_MIGRATION phase=trigger"
        failure := catch: control.write #[1]
        if failure and failure != "GATT_DATABASE_CHANGED": throw failure
        print "BLUEZ_MIGRATION triggered=true"
        print "BLUEZ_MIGRATION phase=control-read"
        state/ByteArray? := null
        with-timeout --ms=10_000:
          while not state:
            // Even raw reads reject a result invalidated while in flight.
            // Only this fixture's control handle is guaranteed not to move.
            failure = catch: state = connection.read control.handle
            if failure and failure != "GATT_DATABASE_CHANGED": throw failure
        if state != #[1]: throw "MIGRATION_NOT_FINISHED"
        failure = catch: original.read
        if failure != "GATT_DATABASE_CHANGED": throw "STALE_RECORD_ACCEPTED"
        failure = catch: original.write #[123]
        if failure != "GATT_DATABASE_CHANGED": throw "STALE_WRITE_ACCEPTED"
        print "BLUEZ_MIGRATION stale-rejected=true"
        fresh/service.CharacteristicRecord? := null
        after/ByteArray? := null
        with-timeout --ms=10_000:
          while not after:
            // Removal and addition are separate changes. Only retry read-only
            // discovery and validation; no write is replayed.
            failure = catch:
              fresh = find connection target-uuid #[0xf1, 0xff]
              after = fresh.read
            if failure and failure != "GATT_DATABASE_CHANGED": throw failure
        if fresh.handle == original.handle: throw "HANDLE_NOT_MOVED"
        if after != #[8]: throw "MOVED_VALUE_MISMATCH"
        print "BLUEZ_MIGRATION rediscovered=true"
        fresh.write #[42]
        if fresh.read != #[42]: throw "MOVED_WRITE_MISMATCH"
        system.process-stats --gc
        if before != #[7] or after != #[8]: throw "RETAINED_VALUE_MISMATCH"
        print "BLUEZ_MIGRATION old=$(original.handle) new=$(fresh.handle) stale-rejected=true retained=true written=true"
    print "BLUEZ_MIGRATION COMPLETE"
  finally:
    client.close

find connection/service.Connection service-uuid/ByteArray value-uuid/ByteArray -> service.CharacteristicRecord:
  services := connection.database.discover-services.filter: it.uuid == service-uuid
  if services.size != 1: throw "WRONG_SERVICE_COUNT"
  values := services[0].characteristics.filter:
    it.uuid == value-uuid or (value-uuid == #[0xf1, 0xff] and
        it.uuid == (fixture.wire-uuid "0000fff1-0000-1000-8000-00805f9b34fb"))
  if values.size != 1: throw "WRONG_CHARACTERISTIC_COUNT"
  return values[0]
