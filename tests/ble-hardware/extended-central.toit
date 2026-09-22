// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.att
import ble.experimental.extended-central as extended
import ble.experimental.hci
import ble.experimental.linux
import encoding.hex
import system

main args/List:
  if args.size != 2: throw "Usage: extended-central.toit <adapter index> <public peer address>"
  address := (hex.decode (args[1].replace --all ":" "")).reverse
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  host/extended.Central? := null
  try:
    info := hci.initialize controller
    extended.configure controller info
    host = extended.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    print "EXTENDED_CENTRAL address=$(hex.encode info.address.reverse) peer=$(hex.encode address.reverse)"
    before := system.process-stats --gc
    retained := []
    2.repeat: | cycle/int |
      link := host.connect address --address-type=0 --timeout=(Duration --s=20)
      client := att.Client host link
      try:
        100.repeat: | index/int |
          value := client.read 3
          if value != "Toit HCI".to-byte-array: throw "EXTENDED_VALUE_MISMATCH"
          if index == 0: retained.add value
          if index % 10 == 0: system.process-stats --gc
        host.disconnect link
        link.wait-disconnected
      finally:
        client.close
      print "EXTENDED_CENTRAL cycle=$cycle reads=100 handle=$(link.info.handle)"
    retained.do:
      if it != "Toit HCI".to-byte-array: throw "EXTENDED_RETAINED_VALUE_CHANGED"
    after := system.process-stats
    full := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if full < 20: throw "EXTENDED_GC_COUNT"
    print "EXTENDED_CENTRAL COMPLETE reads=200 retained=$(retained.size) full-gcs=$full"
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
