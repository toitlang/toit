// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.advertising-set as advertising
import .fixtures.hci-echo as fixture

main args/List:
  if args.size > 1: throw "Usage: scan-advertiser.toit [duration seconds]"
  seconds := args.is-empty ? 30 : (int.parse args[0])
  if not 1 <= seconds <= 600: throw "INVALID_ARGUMENT"
  controller := hci.Controller (linux.LinuxTransport 0)
  try:
    hci.initialize controller
    data := #[2, 1, 6, 17, 7] + (fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001")
    controller.command 0x2006 advertising.parameters
    controller.command 0x2008 (advertising.data data)
    controller.command 0x200a #[1]
    print "SCAN_ADVERTISER READY"
    sleep --ms=(seconds * 1000)
    controller.command 0x200a #[0]
    print "SCAN_ADVERTISER COMPLETE"
  finally:
    controller.close
    controller.wait-closed
