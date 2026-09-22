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
  database := attributes.Database.with-defaults --name="Toit long read" --value-limit=512
  service := fixture.wire-uuid "9f6c2000-8e2a-4b13-9e97-94f353eeb001"
  database.add-service service
  handle := database.add-characteristic (fixture.wire-uuid "9f6c2001-8e2a-4b13-9e97-94f353eeb001")
      --read
      --dynamic-read
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  reads := 0
  blobs := 0
  before := system.process-stats --gc
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
    print "VHCI_LONG_READ READY handle=$handle"
    link := host.accept (#[2, 1, 6, 17, 7] + service) --timeout=(Duration --s=60)
    server := gatt-server.Server host link database
    server.serve-with-reads
        (: | request/attributes.ReadRequest |
          if request.handle != handle: throw "UNEXPECTED_LONG_READ_HANDLE"
          reads++
          if request.opcode == 0x0c: blobs++
          system.process-stats --gc
          request.reply (ByteArray 512: it % 251))
        (: | written/int value/ByteArray | throw "UNEXPECTED_WRITE")
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if reads < 48 or blobs < 46 or gcs < reads: throw "LONG_READ_INCOMPLETE"
  print "VHCI_LONG_READ COMPLETE reads=$reads blobs=$blobs full-gcs=$gcs"
