// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
A heart rate client on the experimental application API.

Finds the peripheral of `next-peripheral.toit`, prints what the link looks
  like, receives a few measurements and resets the energy counter.
*/

import ble.experimental.next as ble

HEART-RATE ::= ble.BleUuid "180d"
MEASUREMENT ::= ble.BleUuid "2a37"
CONTROL-POINT ::= ble.BleUuid "2a39"

main:
  adapter := ble.Adapter
  try:
    run adapter
  finally:
    adapter.close

run adapter/ble.Adapter:
  report := adapter.find --service=HEART-RATE --duration=(Duration --s=20)
  if not report: throw "no heart rate peripheral found"
  print "found: $report"
  adapter.with-connection report.address: | connection/ble.Connection |
    print "connected: phy=$connection.phy mtu=$connection.mtu rssi=$connection.rssi dBm"
    print "  $connection.parameters, $connection.data-length"
    service := connection.discover-service HEART-RATE
    measurement := service.characteristic MEASUREMENT
    measurement.subscribe: | values/ble.Values |
      3.repeat: print "heart rate: $(values.receive[1])"
    (service.characteristic CONTROL-POINT).write #[1]
    error := catch: (service.characteristic CONTROL-POINT).write #[2]
    print "refused command: $error"
    connection.disconnect
    print "disconnected: $connection.wait-closed"
