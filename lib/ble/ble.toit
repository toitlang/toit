// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .adapter
import .advertisement
import .host
import .local
import .remote
import .uuid

export *

/**
Bluetooth Low Energy.

An application opens the device's $Adapter and takes one of its two
  roles. As a central ($Adapter.central), a $Central scans for nearby
  devices ($Central.scan) and connects to one ($Central.connect), whose
  $RemoteDevice, $RemoteService and $RemoteCharacteristic give access to
  the peer's services. As a peripheral ($Adapter.peripheral), a
  $Peripheral publishes $LocalService and $LocalCharacteristic attributes
  ($Peripheral.add-service, $Peripheral.deploy) and advertises them
  ($Peripheral.start-advertise).

Services, characteristics and descriptors are identified by a $BleUuid.
  Advertising data is an $Advertisement made of $DataBlock fields, both when
  sent and when received in a scan.

The package runs on the Toit host everywhere: the $Adapter reaches the
  radio through the BLE service provider, which is built into the ESP32
  firmware and runs in-process on Linux. macOS is pending its provider.

Deprecated. Use `ble.v2` (`import ble.v2`) instead.

This first version of the API keeps working as documented; it is
  implemented on `ble.v2`, which gives new code one connection class for
  both roles with connect and disconnect events, link details, and a GATT
  server defined once.
*/
