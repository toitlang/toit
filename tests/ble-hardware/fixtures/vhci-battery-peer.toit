// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.esp32
import ble.experimental.gatt-server
import ble.experimental.hci

main:
  2.repeat: | cycle/int |
    controller := hci.Controller (esp32.Esp32Transport)
    host/central.Central? := null
    try:
      info := hci.initialize controller
      host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
      service := ble.BleUuid (cycle == 0 ? "180F" : "0000180F-0000-1000-8000-00805F9B34FB")
      level := ble.BleUuid (cycle == 0 ? "2A19" : "00002A19-0000-1000-8000-00805F9B34FB")
      value := cycle == 0 ? 73 : 100
      database := attributes.Database.with-defaults --name="Toit battery fixture"
      database.add-service (service.to-byte-array --reversed)
      database.add-characteristic (level.to-byte-array --reversed) --read --value=(ByteArray 1 --initial=value)
      print "BATTERY_PEER READY cycle=$cycle uuid-bytes=$(service.to-byte-array.size) value=$value"
      link := host.accept #[2, 1, 6, 3, 3, 0x0f, 0x18] --timeout=(Duration --s=30)
      server := gatt-server.Server host link database
      with-timeout --ms=10_000:
        server.serve: | handle/int bytes/ByteArray | throw "UNEXPECTED_BATTERY_WRITE"
      print "BATTERY_PEER DISCONNECTED cycle=$cycle"
    finally:
      if host:
        host.close
        host.wait-closed
      else:
        controller.close
        controller.wait-closed
  print "BATTERY_PEER COMPLETE connections=2"
