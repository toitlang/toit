// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main: run

run --migrate/bool=false:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    uuid := fixture.wire-uuid "9f6c4300-8e2a-4b13-9e97-94f353eeb001"
    peer/service.ScanReport? := null
    client.scan --duration=(Duration --s=20) --service-uuid=uuid: | report/service.ScanReport |
      if report.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8] or report.address-type != 0: continue.scan true
      peer = report
      false
    if not peer: throw "REFERENCE_NOT_FOUND"
    client.with-connection peer.address --address-type=peer.address-type: | connection/service.Connection |
      connection.with-service-changed:
        record := discover connection uuid
        before := record.read
        if before != #[7]: throw "INITIAL_VALUE_MISMATCH"
        failure := catch: record.read
        if failure != "GATT_DATABASE_CHANGED": throw "MISSING_IN_FLIGHT_INVALIDATION"
        failure = catch: record.read
        if failure != "GATT_DATABASE_CHANGED": throw "STALE_RECORD_ACCEPTED"
        fresh := discover connection uuid
        if migrate and fresh.handle == record.handle: throw "HANDLE_NOT_MOVED"
        after := fresh.read
        system.process-stats --gc
        if before != #[7] or after != #[8]: throw "RETAINED_VALUE_MISMATCH"
        if migrate:
          fresh.write #[42]
          if fresh.read != #[42]: throw "MOVED_WRITE_MISMATCH"
          print "SERVICE_CACHE migrated=true old=$(record.handle) new=$(fresh.handle) written=true"
        print "SERVICE_CACHE invalidated=true rediscovered=true retained=true"
    print "SERVICE_CACHE COMPLETE"
  finally:
    client.close

discover connection/service.Connection uuid/ByteArray -> service.CharacteristicRecord:
  services := connection.database.discover-services.filter: it.uuid == uuid
  if services.size != 1: throw "WRONG_SERVICE_COUNT"
  values := services[0].characteristics.filter: it.uuid == #[0xf1, 0xff]
  if values.size != 1: throw "WRONG_CHARACTERISTIC_COUNT"
  return values[0]
