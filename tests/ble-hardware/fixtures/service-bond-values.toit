// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure
    uuid := fixture.wire-uuid "9f6c4200-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    encrypted := session.add-characteristic #[1, 0xff] --read --encrypted --dynamic-read
    authenticated := session.add-characteristic #[2, 0xff] --read --authenticated --value=#[43]
    if encrypted != 12 or authenticated != 14: throw "UNEXPECTED_FIXTURE_LAYOUT"
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "BOND_SERVICE_APP READY"
    session.peer
    reads := 0
    retained/ByteArray? := null
    session.serve
        (: | request/service.Request |
          if request.handle != encrypted: throw "WRONG_REQUEST_HANDLE"
          if retained and retained != #[42]: throw "RETAINED_VALUE_CHANGED"
          value := #[42].copy
          system.process-stats --gc
          retained = value
          reads++
          request.reply value)
        (: unreachable)
        (: unreachable)
    if reads != 2: throw "UNEXPECTED_READ_COUNT"
    print "BOND_SERVICE_APP COMPLETE reads=$reads retained=true"
  finally:
    client.close
