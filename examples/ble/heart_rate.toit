// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// The standard BLE peripheral demo for simulating a heart rate monitor.

import ble show *
import uuid show Uuid

GATT_IO_UUID ::= #[0x18, 0x25]

main:
  adapter := Adapter
  peripheral_manager := adapter.peripheral_manager

  service := peripheral_manager.add_service
      BleUUID GATT_IO_UUID

  /* Characteristic: SEND DATA */
  heart_rate_send := service.add_notification_characteristic
      BleUUID #[0x63, 0x4b, 0x3c, 0x6e, 0xac, 0x41, 0x40, 0x85,
                0xa9, 0x7c, 0xdd, 0x68, 0x7f, 0xa1, 0xe5, 0x0d]

  /* Characteristic: RECEIVE DATA */
  heart_rate_receive := service.add_write_only_characteristic
      BleUUID #[0x63, 0x4b, 0x3c, 0x6e, 0x1c, 0x41, 0x40, 0x85,
                0xa9, 0x7c, 0xdd, 0x68, 0x7f, 0xa1, 0xe5, 0x0d]

  service.deploy

  peripheral_manager.start_advertise
    AdvertisementData
        --name="Toit heart rate demo"
    --connection_mode=platform==PLATFORM_MACOS?BLE_CONNECT_MODE_NONE:BLE_CONNECT_MODE_UNDIRECTIONAL

  task::
    simulated_heart_rate := 60
    while true:
      sleep --ms=500
      heart_rate_send.value = #[0x06, simulated_heart_rate]
      simulated_heart_rate++
      if simulated_heart_rate == 130: simulated_heart_rate = 60

  while true:
    print
      "Heart rate app received data $(heart_rate_receive.value)"
