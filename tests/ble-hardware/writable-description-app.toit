// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure --value-limit=512 --mtu-limit=247
    session.add-service #[0xf0, 0xff]
    value := session.add-characteristic #[0xf1, 0xff] --read --value=#[42]
    vendor := session.add-descriptor value #[0xf2, 0xff] --write --value=#[7]
    description := session.add-descriptor value #[1, 0x29] --write --value=#[65]
    before := system.process-stats
    print "WRITABLE_DESCRIPTION_APP ADVERTISING"
    session.start #[2, 1, 6, 3, 3, 0xf0, 0xff]
    if session.peer != [#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a], 0]: throw "WRONG_PEER"
    expected := [(ByteArray 509 --initial=65) + "€".to-byte-array, "€".to-byte-array, #[]]
    retained := []
    session.serve
        (: | _ | unreachable)
        (: | _ | unreachable)
        (: | handle/int bytes/ByteArray |
          if handle != description or retained.size >= expected.size: throw "UNEXPECTED_WRITE"
          if bytes != expected[retained.size]: throw "WRONG_DESCRIPTION"
          retained.add bytes
          20.repeat: system.process-stats --gc
          retained.size.repeat: | index/int |
            if retained[index] != expected[index]: throw "RETAINED_DESCRIPTION_CHANGED"
          if (session.value vendor) != #[7]: throw "FAILED_TRANSACTION_CHANGED_VENDOR")
    if retained != expected: throw "INCOMPLETE_WRITES"
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 60: throw "MISSING_GC"
    print "WRITABLE_DESCRIPTION_APP COMPLETE writes=3 retained=true full-gcs=$gcs"
  finally:
    client.close
