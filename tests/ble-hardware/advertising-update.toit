// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import expect show *
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    2.repeat: | mode/int |
      advertiser/service.Advertising? := null
      try:
        4.repeat: | phase/int |
          data := payload mode phase
          response := mode == 1 ? (scan-response mode phase) : #[]
          before := system.process-stats
          if phase == 0:
            advertiser = client.start-advertising data --scan-response=response --scannable=(mode == 1)
          else:
            advertiser.update data --scan-response=response
          data.fill 0
          response.fill 0
          after := system.process-stats --gc
          if after[system.STATS-INDEX-FULL-GC-COUNT] <= before[system.STATS-INDEX-FULL-GC-COUNT]:
            throw "ADVERTISING_UPDATE_GC_MISSING"
          print "ADVERTISING_UPDATE APPLIED mode=$mode phase=$phase gc=true"
          sleep --ms=5_000
      finally:
        if advertiser: advertiser.stop
      expect advertiser.is-closed
      print "ADVERTISING_UPDATE STOPPED mode=$mode"
      sleep --ms=3_000
    print "ADVERTISING_UPDATE COMPLETE"
  finally:
    client.close

payload mode/int phase/int -> ByteArray:
  if phase == 3: return #[]
  bytes := ByteArray 31 --initial=(0x30 + phase)
  bytes.replace 0 #[2, 1, 6, 27, 0xff, 0xff, 0xff, 'u', 'p', 'd', mode, phase]
  return bytes

scan-response mode/int phase/int -> ByteArray:
  if phase == 3: return #[]
  bytes := ByteArray 31 --initial=(0x41 + phase)
  bytes.replace 0 #[30, 9, '0' + mode, '0' + phase]
  return bytes
