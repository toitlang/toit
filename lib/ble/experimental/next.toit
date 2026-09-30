// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ble show BleUuid Advertisement DataBlock

import .next.adapter
import .next.connection
import .next.peripheral
import .next.types

/**
An experimental application API for the Toit BLE host.

Import it as `import ble.experimental.next as ble`. It runs where the BLE
  service runs: on controller-only firmware with a provider container, and
  on Linux through `ble.experimental.next.linux`. The design and its open
  questions are in `docs/ble/api.md`; the `ble` package keeps working beside
  it.

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
