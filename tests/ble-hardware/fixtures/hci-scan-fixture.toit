// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising-set as advertising
import ble.experimental.hci
import ble.experimental.linux
import .hci-echo as fixture

main args/List:
  if not 1 <= args.size <= 2: throw "Usage: hci-scan-fixture.toit <adapter index> [seconds]"
  seconds := args.size == 2 ? (int.parse args[1]) : 60
  if not 1 <= seconds <= 3600: throw "INVALID_ARGUMENT"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  enabled := false
  try:
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_FIXTURE_ADAPTER"
    parameters := advertising.parameters
    parameters[4] = 3  // ADV_NONCONN_IND: this fixture never accepts connections.
    controller.command 0x2006 parameters
    controller.command 0x2008 (advertising.data (#[2, 1, 6, 17, 7] + (fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001")))
    controller.command 0x200a #[1]
    enabled = true
    print "SCAN_FIXTURE READY"
    sleep --ms=(seconds * 1000)
  finally:
    try:
      if enabled:
        critical-do --no-respect-deadline: controller.command 0x200a #[0]
    finally:
      controller.close
      controller.wait-closed
  print "SCAN_FIXTURE COMPLETE"
