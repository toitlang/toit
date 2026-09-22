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
    session := client.configure --value-limit=512 --mtu-limit=517
    uuid := fixture.wire-uuid "9f6c4000-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    encrypted := session.add-characteristic (fixture.wire-uuid "9f6c4001-8e2a-4b13-9e97-94f353eeb001")
        --read
        --encrypted
        --dynamic-read
    authenticated := session.add-characteristic (fixture.wire-uuid "9f6c4002-8e2a-4b13-9e97-94f353eeb001")
        --read
        --authenticated
        --value=#[43]
    if encrypted != 12 or authenticated != 14: throw "UNEXPECTED_FIXTURE_LAYOUT"
    session.start (#[2, 1, 6, 17, 7] + uuid)
    print "SECURE_SERVICE_APP READY value-limit=512 mtu-limit=517"
    session.peer
    reads := 0
    retained/ByteArray? := null
    session.serve
        (: | request/service.Request |
          if request.handle != encrypted: throw "AUTHENTICATED_HANDLER_REACHED"
          if session.mtu != 517: throw "EXPECTED_MTU_517"
          value := ByteArray 512: (it + 42) % 251
          if retained != null and retained != value: throw "RETAINED_VALUE_CHANGED"
          retained = value
          system.process-stats --gc
          reads++
          print "SECURE_SERVICE_APP READ count=$reads bytes=$(value.size) mtu=517"
          request.reply value)
        (: unreachable)
        (: unreachable)
    if reads != 2: throw "UNEXPECTED_READ_COUNT"
    print "SECURE_SERVICE_APP COMPLETE reads=$reads retained=true"
  finally:
    client.close
