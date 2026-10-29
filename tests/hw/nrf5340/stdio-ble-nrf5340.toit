// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ble
import .stdio-nrf5340 as stdio

main:
  adapter := ble.Adapter
  adapter.peripheral.start-advertise (ble.Advertisement --name="toit-stdin-test")
  print "STDIN BLE advertising active"
  // The common test exits with its blocked stdin reader and this advertiser
  // still live, so VM teardown must retire both resources.
  stdio.main
