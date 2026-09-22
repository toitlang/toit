// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.hci
import ble.experimental.controller-states as states
import ble.experimental.linux
import encoding.hex

main args/List:
  if args.size != 1: throw "Usage: hci-info.toit <adapter index>"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  try:
    info := hci.initialize controller
    print "HCI address=$(hex.encode info.address.reverse) version=$(hex.encode info.version)"
    print "HCI commands=$(hex.encode info.commands)"
    print "HCI features=$(hex.encode info.features) le-features=$(hex.encode info.le-features)"
    print "HCI acl-length=$(info.acl-length) acl-count=$(info.acl-count)"
    supported := states.read controller
    print "HCI legacy-states=$(hex.encode supported.bytes)"
  finally:
    controller.close
