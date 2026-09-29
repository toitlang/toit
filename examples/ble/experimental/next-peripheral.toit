// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
A heart rate peripheral on the experimental application API.

Runs on controller-only firmware beside a BLE provider container (see
  `gatt-provider.toit`). It prints every central that connects and the
  reason it left, the link each one gets, and what they write to the
  control point.
*/

import ble.experimental.next as ble

HEART-RATE ::= ble.BleUuid "180d"
MEASUREMENT ::= ble.BleUuid "2a37"
CONTROL-POINT ::= ble.BleUuid "2a39"

main:
  adapter := ble.Adapter
  print "address: $adapter.address"
  if adapter.supports-tx-power-control:
    print "tx power: $(adapter.set-tx-power 9) dBm"

  server := ble.GattServer
  service := server.add-service HEART-RATE
  measurement := service.add-characteristic MEASUREMENT --notify
  service.add-characteristic CONTROL-POINT --write
      --validate=(:: | connection/ble.Connection value/ByteArray |
        // The only defined command is 1, "reset energy expended".
        if value != #[1]: throw (ble.AttError 0x80))
      --on-write=(:: | connection/ble.Connection value/ByteArray |
        print "$connection.peer reset the energy counter")

  peripheral := adapter.peripheral server
      --advertisement=(ble.Advertisement --name="Toit next" --services=[HEART-RATE])

  task --background::
    beat := 60
    while true:
      // Flags 0: an 8-bit heart rate follows.
      measurement.notify #[0, beat]
      beat = beat == 100 ? 60 : beat + 1
      sleep --ms=1000

  while true:
    connection := peripheral.accept
    print "connected: $connection.peer"
    task:: watch connection

watch connection/ble.Connection:
  catch:
    // A heart rate sensor is happy with a slow connection: ask the central.
    error := catch:
      applied := connection.request-parameters
          --interval-min=(Duration --ms=45)
          --interval-max=(Duration --ms=60)
      print "parameters: $applied"
    if error: print "parameters refused: $error"
    // Give the central time to settle its PHY.
    sleep --ms=2_000
    print "link: $connection.peer phy=$connection.phy mtu=$connection.mtu rssi=$connection.rssi dBm tx=$connection.tx-power dBm"
    print "  $connection.parameters, $connection.data-length"
  reason := connection.wait-closed
  print "disconnected: $connection.peer ($reason)"
  connection.close
