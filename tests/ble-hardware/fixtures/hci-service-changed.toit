// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server as gatt
import ble.experimental.hci
import ble.experimental.linux
import monitor
import .hci-echo as fixture

main args/List:
  if args.size != 1: throw "Usage: hci-service-changed.toit <adapter>"
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/central.Central? := null
  waiter/Task? := null
  try:
    info := hci.initialize controller
    if info.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: throw "WRONG_CONTROLLER"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    database := attributes.Database.with-defaults
    changed/int := database.service-changed-handle
    uuid := fixture.wire-uuid "9f6c4300-8e2a-4b13-9e97-94f353eeb001"
    database.add-service uuid
    value := database.add-characteristic #[0xf1, 0xff] --read --dynamic-read
    print "SERVICE_CHANGED_PEER READY"
    link := host.accept (#[2, 1, 6, 17, 7] + uuid) --timeout=(Duration --s=60)
    if link.info.address != #[1, 0x30, 0x23, 0xf2, 0x3a, 0xc8] or link.info.address-type != 1:
      throw "WRONG_FIXTURE_PEER"
    server := gatt.Server host link database
    reads := 0
    confirmed := monitor.Latch
    server.serve-with-reads
        (: | request/attributes.ReadRequest |
          if request.handle != value: throw "WRONG_READ"
          reads++
          if reads == 2:
            receipt := server.indicate changed
            if not receipt: throw "MONITOR_NOT_SUBSCRIBED"
            waiter = task::
              receipt.wait
              confirmed.set true
          request.reply (reads >= 2 ? #[8] : #[7]))
        (: | _ _ | unreachable)
    if reads != 3: throw "WRONG_READ_COUNT"
    with-timeout --ms=3_000: confirmed.get
    print "SERVICE_CHANGED_PEER COMPLETE reads=3 confirmed=true"
  finally:
    if waiter: waiter.cancel
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
