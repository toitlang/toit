// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import encoding.hex
import system

main:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    count := 0
    held/service.ScanReport? := null
    statistics := client.scan --duration=(Duration --s=5): | report/service.ScanReport |
      count++
      held = report
      system.process-stats --gc
      print "SERVICE_SCAN peer=$(hex.encode report.address.reverse) type=$(report.address-type) rssi=$(report.rssi) connectable=$(report.connectable) scannable=$(report.scannable) scan-response=$(report.scan-response)"
      true
    print "SERVICE_SCAN COMPLETE reports=$count dropped-events=$(statistics[0]) dropped-reports=$(statistics[1]) unread=$(statistics[2]) retained=$(held != null)"
  finally:
    client.close
