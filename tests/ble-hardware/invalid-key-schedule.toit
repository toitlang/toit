// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..ble-smp-invalid-key-schedule-test as fixture
import system

main:
  before := system.process-stats --gc
  print "INVALID_KEY_NATIVE START"
  with-timeout --ms=180_000:
    fixture.schedule false
    fixture.schedule true
  after := system.process-stats --gc
  full := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  compacting := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
  if full < 49 or compacting < 1: throw "INVALID_KEY_NATIVE_GC_COUNTS"
  print "INVALID_KEY_NATIVE COMPLETE full-gcs=$full compacting-gcs=$compacting"
