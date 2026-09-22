// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import system
import .hci-echo as fixture

main:
  run

run --mtu-limit/int=23 --expected-mtu/int?=null:
  database := attributes.Database.with-defaults --name="Toit long write" --value-limit=512
      --mtu-limit=mtu-limit
  service := fixture.wire-uuid "9f6c3000-8e2a-4b13-9e97-94f353eeb001"
  database.add-service service
  handle := database.add-characteristic (fixture.wire-uuid "9f6c3001-8e2a-4b13-9e97-94f353eeb001")
      --read
      --write
      --validate-write
      --value=#[7]
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  writes := 0
  before := system.process-stats --gc
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=(max 65 mtu-limit)
    print "VHCI_LONG_WRITE READY handle=$handle"
    link := host.accept (#[2, 1, 6, 17, 7] + service) --timeout=(Duration --s=60)
    server := gatt-server.Server host link database
    server.serve-with-requests
        (: | read/attributes.ReadRequest | throw "UNEXPECTED_DYNAMIC_READ")
        (: | request/attributes.WriteRequest |
          expected := writes == 0 ? (ByteArray 512: it % 251) : #[]
          if writes >= 2 or request.handle != handle or request.value != expected:
            throw "LONG_WRITE_VALIDATION_FAILED"
          if expected-mtu and server.mtu != expected-mtu: throw "UNEXPECTED_NEGOTIATED_MTU"
          if writes == 0 and server.mtu == 23 and request.opcode != 0x18:
            throw "EXPECTED_PREPARED_WRITE"
          print "VHCI_LONG_WRITE mtu=$(server.mtu) opcode=$request.opcode"
          if (database.value handle) != (writes == 0 ? #[7] : (ByteArray 512: it % 251)):
            throw "LONG_WRITE_COMMITTED_EARLY"
          system.process-stats --gc
          request.accept)
        (: | written/int value/ByteArray |
          writes++
          print "VHCI_LONG_WRITE committed=$writes bytes=$(value.size)")
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if writes != 2 or gcs < 2: throw "LONG_WRITE_INCOMPLETE"
  print "VHCI_LONG_WRITE COMPLETE writes=$writes full-gcs=$gcs"
