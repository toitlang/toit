// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Board application for tests/ble-hardware/peripheral-client-check.sh: a
// peripheral that, once a central connected, reads the central's own GATT
// database over the same link (its GAP Device Name and its services) while
// the central discovers this device's.

import ble.experimental.next as ble

main:
  adapter := ble.Adapter
  print "address: $adapter.address"
  server := ble.GattServer
  service := server.add-service (ble.BleUuid "fff0")
  service.add-characteristic (ble.BleUuid "fff1") --read --value="served".to-byte-array
  peripheral := adapter.peripheral server
      --advertisement=(ble.Advertisement --name="Toit client" --services=[ble.BleUuid "fff0"])
  connection := peripheral.accept
  print "connected: $connection.peer"
  error := catch --trace:
    gap := connection.discover-service (ble.BleUuid "1800")
    name := (gap.characteristic (ble.BleUuid "2a00")).read
    print "PERIPHERAL_CLIENT central-name=$name.to-string"
    uuids := connection.discover-services.map: | remote/ble.RemoteService | remote.uuid
    print "PERIPHERAL_CLIENT central-services=$uuids"
  if error: print "PERIPHERAL_CLIENT failed: $error"
  print "disconnected: $connection.wait-closed"
  connection.close
  peripheral.close
