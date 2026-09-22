// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci
import io
import system

// Dedicated peripheral for the optional independent Read By Type matrix.
main: run

run --diagnostics/bool=false --transactions/bool=false:
  before := system.process-stats --gc
  controller := hci.Controller (diagnostics ? (Radio_) : (esp32.Esp32Transport))
  host/central.Central? := null
  reads := 0
  writes := 0
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=517
    database := attributes.Database --value-limit=512 --mtu-limit=517
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --write --notify --dynamic-read --value=#[7]
    database.add-characteristic #[0xf1, 0xff] --read --write --dynamic-read --value=#[8]
    debug "TYPE_PAGES READY"
    with-timeout --ms=90_000:
      link := host.accept #[2, 1, 6] --timeout=(Duration --s=30)
      debug "TYPE_PAGES CONNECTED"
      server := gatt-server.Server host link database
      try:
        server.serve-with-reads
            (: | request/attributes.ReadRequest |
              value := database.value request.handle
              system.process-stats --gc
              request.reply value
              reads++)
            (: | handle/int value/ByteArray |
              system.process-stats --gc
              if (database.value handle) != value: throw "TYPE_PAGES_CHANGED_WRITE"
              writes++)
      finally:
        server.close
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
  after := system.process-stats --gc
  gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if reads < (transactions ? 18 : 64) or writes != (transactions ? 2 : 32) or gcs < (transactions ? 20 : 96):
    throw "TYPE_PAGES_INCOMPLETE"
  debug "TYPE_PAGES COMPLETE reads=$reads writes=$writes full-gcs=$gcs"

// Only public connection and advertising status fields, bounded per lifetime.
// Defer printing until teardown to avoid serial output in the receive path.
class Radio_ extends esp32.Esp32Transport:
  records_/List := []

  receive -> ByteArray:
    packet := super
    if records_.size < 32 and packet.size >= 3 and packet[0] == 4:
      if packet.size == 22 and packet[1..4] == #[0x3e, 19, 1]:
        records_.add ["connection", packet[4], (io.LITTLE-ENDIAN.uint16 packet 5), packet[7]]
      else if packet.size == 7 and packet[1..3] == #[5, 4]:
        records_.add ["disconnect", packet[3], (io.LITTLE-ENDIAN.uint16 packet 4), packet[6]]
      else if packet.size == 7 and packet[1..3] == #[0x0e, 4] and packet[4..6] == #[0x0a, 0x20]:
        records_.add ["advertising", packet[6]]
    return packet

  close -> none:
    try:
      super
    finally:
      records := records_
      records_ = []
      records.do: debug "TYPE_PAGES RADIO $it"
