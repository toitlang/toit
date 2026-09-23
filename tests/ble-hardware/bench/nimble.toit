// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The NimBLE side of the memory comparison: the `ble` package on the default
// firmware, advertising the same service and pushing notifications as fast as
// the API allows. A write without subscribers is a cheap no-op, so the loop
// runs continuously; the central measures what arrives.

import ble show *
import .stats as stats
import .uuids as uuids

main:
  stats.report "nimble" "boot"
  adapter := Adapter
  peripheral := adapter.peripheral
  stats.report "nimble" "adapter"
  service := peripheral.add-service (BleUuid uuids.SERVICE-STRING)
  value := service.add-notification-characteristic (BleUuid uuids.VALUE-STRING)
  peripheral.deploy
  peripheral.start-advertise
      --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL
      Advertisement --services=[BleUuid uuids.SERVICE-STRING]
  stats.report "nimble" "advertising"
  stats.periodic "nimble"
  payload := ByteArray 20: it
  writes := 0
  failures := 0
  while true:
    // A subscriber that disconnects mid-write makes the backend throw.
    if (catch: value.write payload): failures++
    writes++
    if writes % 10000 == 0: print "BENCH nimble writes=$writes failures=$failures"
    yield
