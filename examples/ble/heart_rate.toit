// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// The standard BLE peripheral demo for simulating a heart rate monitor.

import ble show *
import system
import system show platform
import uuid show Uuid

GATT-IO-UUID ::= #[0x18, 0x25]

main:
  adapter := Adapter
  peripheral := adapter.peripheral

  service := peripheral.add-service
      BleUuid GATT-IO-UUID

  /* Characteristic: SEND DATA */
  heart-rate-send := service.add-notification-characteristic
      BleUuid #[0x63, 0x4b, 0x3c, 0x6e, 0xac, 0x41, 0x40, 0x85,
                0xa9, 0x7c, 0xdd, 0x68, 0x7f, 0xa1, 0xe5, 0x0d]

  /* Characteristic: RECEIVE DATA */
  heart-rate-receive := service.add-write-only-characteristic
      BleUuid #[0x63, 0x4b, 0x3c, 0x6e, 0x1c, 0x41, 0x40, 0x85,
                0xa9, 0x7c, 0xdd, 0x68, 0x7f, 0xa1, 0xe5, 0x0d]

  peripheral.deploy

  connection-mode := platform == system.PLATFORM-MACOS
      ? BLE-CONNECT-MODE-NONE
      : BLE-CONNECT-MODE-UNDIRECTIONAL
  peripheral.start-advertise
      --connection-mode=connection-mode
      AdvertisementData --name="Toit heart rate demo"

  task::
    simulated-heart-rate := 60
    while true:
      sleep --ms=500
      heart-rate-send.write #[0x06, simulated-heart-rate]
      simulated-heart-rate++
      if simulated-heart-rate == 130: simulated-heart-rate = 60

  while true:
    print
      "Heart rate app received data $(heart-rate-receive.read)"
