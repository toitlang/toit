// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.service.shared-host as shared
import expect show *
import system
import .ble-hci-test as fixture

main:
  factory := Factory
  pool := shared.Host factory
  pool.retain
  set-max-heap-size_ (256 * 1024)
  error := catch: pool.setup: unreachable
  factory.slots.fill null
  system.process-stats --gc
  expect factory.opened
  expect (error == "OUT_OF_MEMORY" or error == "ALLOCATION_FAILED")
  pool.release
  expect pool.released
  expect factory.radio.closed
  expect-throw "GATT_SERVICE_BUSY": pool.retain
  print "SHARED_HOST_PRESSURE COMPLETE"

class Factory implements shared.Factory:
  radio/fixture.FakeTransport ::= fixture.FakeTransport
  slots/List ::= List 16384
  opened/bool := false

  open-transport -> fixture.FakeTransport:
    filled := 0
    failure := catch:
      while filled < slots.size:
        slots[filled] = ByteArray 8 --initial=42
        filled++
    if failure != "OUT_OF_MEMORY" and failure != "ALLOCATION_FAILED":
      throw "PRESSURE_NOT_REACHED"
    // The already-open transport is handed to the controller constructor
    // with insufficient heap for its managed state. No reader is prestarted.
    opened = true
    return radio

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    unreachable
