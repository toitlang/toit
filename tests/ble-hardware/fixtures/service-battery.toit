// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.service.client as service
import encoding.hex

BATTERY-SERVICE ::= ble.BleUuid "180F"
BATTERY-LEVEL ::= ble.BleUuid "2A19"

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    peer/service.ScanReport? := null
    statistics := client.scan --duration=(Duration --s=3) --active
        --service-uuid=(BATTERY-SERVICE.to-byte-array --reversed): | report/service.ScanReport |
      peer = report
      false
    if not peer:
      throw "NO_BATTERY_DEVICE drops=$(statistics[0]),$(statistics[1])"
    client.with-connection peer.address --address-type=peer.address-type: | connection/service.Connection |
      // Discover for this connection; do not retain handles across reconnects.
      services := connection.database.discover-services.filter:
        matches-uuid it.uuid BATTERY-SERVICE
      if services.size != 1: throw "EXPECTED_ONE_BATTERY_SERVICE"
      levels := services[0].characteristics.filter: matches-uuid it.uuid BATTERY-LEVEL
      if levels.size != 1: throw "EXPECTED_ONE_BATTERY_LEVEL"
      value := levels[0].read
      if value.size != 1 or value[0] > 100: throw "INVALID_BATTERY_LEVEL"
      print "Battery level of $(hex.encode peer.address.reverse) (type=$(peer.address-type)): $(value[0])%"
  finally:
    client.close

// Accept the Bluetooth-base expansion as well as the short ATT UUID.
matches-uuid wire/ByteArray uuid/ble.BleUuid -> bool:
  short := uuid.to-byte-array --reversed
  if wire == short: return true
  if short.size != 2: return false
  expanded := ble.BleUuid "0000$(uuid.to-string)-0000-1000-8000-00805f9b34fb"
  return wire == (expanded.to-byte-array --reversed)
