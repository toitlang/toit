// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import monitor
import system
import .hci-echo as fixture

main:
  database := attributes.Database.with-defaults --name="Toit indications" --value-limit=512 --mtu-limit=517
  service := fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001"
  database.add-service service
  value := database.add-characteristic (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001") --indicate
  status := database.add-characteristic (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001") --read --value=#[0]
  controller := hci.Controller (esp32.Esp32Transport)
  host/central.Central? := null
  producer/Task? := null
  finished := monitor.Latch
  confirmed := 0
  before := system.process-stats --gc
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count --receive-limit=517
    print "VHCI_INDICATIONS READY"
    link := host.accept (#[2, 1, 6, 17, 7] + service) --timeout=(Duration --s=60)
    server := gatt-server.Server host link database
    enabled := monitor.Latch
    producer = task::
      try:
        error := catch:
          enabled.get
          if server.mtu != 517: throw "UNEXPECTED_NEGOTIATED_MTU"
          retained := []
          100.repeat: | sequence/int |
            bytes := ByteArray 512: (sequence + it) % 251
            if sequence % 10 == 0: retained.add bytes
            database.set-value value bytes
            receipt := server.indicate value
            if not receipt: throw "INDICATION_NOT_ENABLED"
            system.process-stats --gc
            receipt.wait
            confirmed++
          retained.size.repeat: | index/int |
            if retained[index] != (ByteArray 512: (index * 10 + it) % 251): throw "RETAINED_VALUE_CHANGED"
          database.set-value status #[100]
          print "VHCI_INDICATIONS confirmed=$confirmed mtu=$(server.mtu) retained=$(retained.size)"
        if error:
          server.close
          throw error
      finally:
        critical-do --no-respect-deadline: finished.set true
    server.serve: | handle/int bytes/ByteArray |
      if handle != value + 1: throw "UNEXPECTED_WRITE"
      if bytes == #[2, 0]: enabled.set true
      else if bytes != #[0, 0]: throw "UNEXPECTED_CCCD"
    finished.get
  finally:
    if producer: producer.cancel
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if confirmed != 100 or gcs < 100: throw "INDICATIONS_INCOMPLETE"
  print "VHCI_INDICATIONS COMPLETE confirmed=$confirmed full-gcs=$gcs"
