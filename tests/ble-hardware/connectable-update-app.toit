// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    session := client.configure
    session.add-service #[0xf0, 0xff]
    value := session.add-characteristic #[0xf1, 0xff] --read --write --value=#[0]
    before := system.process-stats
    print "CONNECTABLE_UPDATE ADVERTISING"
    4.repeat: | phase/int |
      data := payload phase
      response := scan-response phase
      if phase == 0:
        session.start data --scan-response=response
      else if not (session.update-advertising data --scan-response=response):
        throw "CONNECTABLE_UPDATE_EARLY_CONNECTION"
      data.fill 0
      response.fill 0
      system.process-stats --gc
      print "CONNECTABLE_UPDATE APPLIED phase=$phase gc=true"
      if phase < 3: sleep --ms=4_000
    if session.peer != [#[0xa9, 0x56, 0xa3, 0x4b, 0x88, 0x8a], 0]: throw "WRONG_PEER"
    if session.update-advertising #[1]: throw "CONNECTABLE_UPDATE_AFTER_CONNECTION"
    retained := []
    count := 0
    session.serve
        (: | _ | unreachable)
        (: | _ | unreachable)
        (: | handle/int bytes/ByteArray |
          if handle != value or bytes != #[count, 42, 43]: throw "CONNECTABLE_UPDATE_WRONG_ECHO"
          if retained.size < 4: retained.add bytes
          count++
          system.process-stats --gc
          retained.size.repeat:
            if retained[it] != #[it, 42, 43]: throw "CONNECTABLE_UPDATE_RETAINED_CHANGED")
    if count != 100: throw "CONNECTABLE_UPDATE_INCOMPLETE"
    after := system.process-stats
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 104: throw "CONNECTABLE_UPDATE_GC_MISSING"
    print "CONNECTABLE_UPDATE_APP COMPLETE writes=100 retained=4 full-gcs=$gcs"
  finally:
    client.close

payload phase/int -> ByteArray:
  if phase == 3: return #[]
  bytes := ByteArray 31 --initial=(0x30 + phase)
  bytes.replace 0 #[2, 1, 6, 27, 0xff, 0xff, 0xff, 'c', 'u', 'p', phase]
  return bytes

scan-response phase/int -> ByteArray:
  if phase == 3: return #[]
  bytes := ByteArray 31 --initial=(0x41 + phase)
  bytes.replace 0 #[30, 9, 'c', 'u', 'p', '0' + phase]
  return bytes
