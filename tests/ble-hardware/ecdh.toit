// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..crypto-ecdh-test as ec-test
import ..ble-sc-ecdh-test as ble-test
import system

main:
  with-timeout --ms=120_000:
    before := system.process-stats --gc
    debug "ECDH_MANAGED START"
    ec-test.main
    debug "ECDH_MANAGED CURVES count=3"
    ble-test.main
    after := system.process-stats --gc
    full := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    compacting := after[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT] - before[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
    if full < 44 or compacting < 1: throw "ECDH_GC_COUNTS"
    debug "ECDH_MANAGED COMPLETE full-gcs=$full compacting-gcs=$compacting"
