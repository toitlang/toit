// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Linux central for tests/ble-hardware/next-check.sh: drives
// examples/ble/v2-peripheral.toit on a board through the
// experimental application API and prints what the link looks like.
//
// Usage: toit.run next-central.snapshot <adapter index> <peripheral address> [phy]

import ble.v2 as ble
import ble.v2.linux as linux

HEART-RATE ::= ble.BleUuid "180d"
MEASUREMENT ::= ble.BleUuid "2a37"
CONTROL-POINT ::= ble.BleUuid "2a39"

main args/List:
  adapter := linux.open (int.parse args[0])
  try:
    run adapter (ble.Address.parse args[1]) (args.size > 2 ? int.parse args[2] : null)
  finally:
    adapter.close

run adapter/ble.Adapter address/ble.Address phy/int? -> none:
  print "NEXT_CENTRAL adapter=$adapter.address 2m=$adapter.supports-phy-2m tx-power-control=$adapter.supports-tx-power-control"
  report := adapter.find --service=HEART-RATE --duration=(Duration --s=20): | candidate/ble.ScanReport |
    candidate.address.bytes == address.bytes
  if not report: throw "NEXT_PERIPHERAL_NOT_FOUND"
  print "NEXT_CENTRAL found $report"
  adapter.with-connection report.peer --phy=phy: | connection/ble.Connection |
    print "NEXT_CENTRAL connected phy=$connection.phy mtu=$connection.mtu rssi=$connection.rssi tx=$connection.tx-power"
    print "NEXT_CENTRAL link $connection.parameters; $connection.data-length"
    service := connection.discover-service HEART-RATE
    values := []
    (service.characteristic MEASUREMENT).subscribe: | stream/ble.Values |
      3.repeat: values.add stream.receive[1]
    print "NEXT_CENTRAL heart-rates=$values"
    control := service.characteristic CONTROL-POINT
    control.write #[1]
    error := catch: control.write #[2]
    if error is not ble.AttError or error.code != 0x80: throw "NEXT_WRONG_REFUSAL $error"
    print "NEXT_CENTRAL refused-write code=0x80"
    parameters := connection.request-parameters
        --interval-min=(Duration --ms=30)
        --interval-max=(Duration --ms=50)
    print "NEXT_CENTRAL parameters $parameters"
    connection.disconnect
    print "NEXT_CENTRAL disconnected $connection.wait-closed"
  print "NEXT_CENTRAL COMPLETE"
