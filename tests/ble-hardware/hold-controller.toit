// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux

// Explicit radio fixture for supervisor signal/cleanup tests. The supervisor
// must verify identity and reserve the adapter before starting this process.
main arguments/List:
  if arguments.size != 1: throw "Usage: hold-controller ADAPTER"
  controller := hci.Controller (linux.LinuxTransport (int.parse arguments[0]))
  try:
    hci.initialize controller
    print "HCI_HOLD READY"
    sleep --ms=60_000
    throw "HCI_HOLD_NOT_INTERRUPTED"
  finally:
    controller.close
    controller.wait-closed
