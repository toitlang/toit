// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.central
import ble.experimental.hci
import ble.experimental.linux
import .fixtures.hci-echo as fixture

main:
  controller := hci.Controller (linux.LinuxTransport 0)
  host/central.Central? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    advertisement := #[2, 1, 6, 17, 7] + (fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001")
    print "CONNECT_DROP READY"
    link := host.accept advertisement --timeout=(Duration --s=30)
    packet := with-timeout --ms=5_000: link.receive
    if packet.channel != 4 or packet.payload != #[2, 23, 0]: throw "EXPECTED_MTU_REQUEST"
    // Deliberately disconnect without answering MTU exchange.
    host.disconnect link
    print "CONNECT_DROP COMPLETE mtu-request=true disconnected=true"
  finally:
    if host: host.close
    else: controller.close
