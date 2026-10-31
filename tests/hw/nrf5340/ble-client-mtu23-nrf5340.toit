// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import .ble-values-nrf5340 as values
import .ble-notify-nrf5340 as notifications

main:
  values.run --mtu=23
  notifications.run --mtu=23
  print "NRF5340 BLE CLIENT MTU23 PASS"
