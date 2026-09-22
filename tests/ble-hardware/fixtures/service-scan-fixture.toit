// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import system
import .hci-echo as fixture

main: run

run --continuous/bool=false:
  with-timeout --ms=90_000: scan continuous

scan continuous/bool:
  client := service.Client
  client.open --timeout=(Duration --s=10)
  try:
    uuid := fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
    held/service.ScanReport? := null
    first-report/int? := null
    elapsed/int := 0
    reports := 0
    before := system.process-stats --gc
    if continuous and not client.capabilities.continuous-scanning:
      throw "CONTINUOUS_SCAN_UNSUPPORTED"
    statistics := client.scan --duration=(Duration --s=10) --continuous=continuous --filter-duplicates=(not continuous) --service-uuid=uuid: | report/service.ScanReport |
      if report.address != #[0xc2, 0xda, 0x2a, 0xac, 0xbe, 8]: continue.scan true
      if report.address-type != 0 or report.event-type != 3: throw "WRONG_FIXTURE_REPORT"
      expected := #[2, 1, 6, 17, 7] + uuid
      if report.data != expected: throw "WRONG_FIXTURE_DATA"
      if not held: held = report
      if not first-report: first-report = Time.monotonic-us --since-wakeup
      reports++
      system.process-stats --gc
      if report.data != expected or held.data != expected: throw "RETAINED_REPORT_CHANGED"
      elapsed = (Time.monotonic-us --since-wakeup) - first-report
      continuous and elapsed < 65_000_000
    if not held: throw "SCAN_FIXTURE_NOT_FOUND"
    if statistics != [0, 0, 0]: throw "UNEXPECTED_SCAN_DROPS"
    if continuous:
      after := system.process-stats
      full-gcs := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
      if reports < 2 or elapsed < 65_000_000 or full-gcs < reports:
        throw "CONTINUOUS_SCAN_NOT_VERIFIED"
      print "SERVICE_CONTINUOUS_SCAN COMPLETE reports=$reports elapsed-awake-us=$elapsed compacting-gcs=$full-gcs retained=true stopped=true drops=0"
    print "SERVICE_SCAN_FIXTURE COMPLETE matched=true retained=true stopped=true drops=0"
  finally:
    client.close
