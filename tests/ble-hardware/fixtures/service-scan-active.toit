// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble
import ble.experimental.service.client as service
import encoding.hex

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    discovered := {:}
    omitted := 0
    statistics := client.scan --duration=(Duration --s=2) --active: | report/service.ScanReport |
      // Address type is part of identity; identical public/random bytes differ.
      identity := "$(report.address-type)/$(hex.encode report.address.reverse)"
      if not discovered.contains identity and discovered.size == 64:
        omitted++
        continue.scan true
      blocks := discovered.get identity --init=: {}
      report.advertisement.data-blocks.do: | block/ble.DataBlock |
        if blocks.size < 64: blocks.add block
        else: omitted++
      true
    discovered.do: | identity/string blocks/Set |
      advertisement := ble.Advertisement blocks.to-list --no-check-size
      print "$identity: $advertisement"
    print "Dropped HCI events: $(statistics[0]); dropped reports: $(statistics[1]); unread reports: $(statistics[2]); omitted entries: $omitted"
  finally:
    client.close
