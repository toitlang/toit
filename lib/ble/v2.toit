// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ble show BleUuid Advertisement DataBlock

import .v2.adapter
import .v2.connection
import .v2.peripheral
import .v2.types

/**
The application API of the Toit BLE host, version 2 of the `ble` package.

Import it as `import ble.v2 as ble`. It runs where the BLE service runs: on
  firmware with a BLE provider, and on Linux through `ble.v2.linux`. Its
  design is described in `docs/ble/api.md`; the `ble` package keeps working
  beside it.

$Adapter is the entry point. As a central, $Adapter.scan and $Adapter.find
  report nearby devices and $Adapter.connect opens a $Connection to one,
  whose $RemoteService, $RemoteCharacteristic and $RemoteDescriptor reach
  the peer's GATT database. As a peripheral, a $GattServer describes this
  device's services, $Adapter.peripheral serves it and $Peripheral.accept
  returns the $Connection of each central that connects; $Adapter.advertise
  broadcasts without accepting connections. Both roles use the same
  $Connection class, which describes the link (its $Peer, role, MTU, PHY,
  parameters, security, RSSI, transmit power) and ends with $Connection.wait-closed
  and a $DisconnectReason. UUIDs are the `ble` package's $BleUuid and
  advertisements its $Advertisement.
*/

export BleUuid Advertisement DataBlock
export *
