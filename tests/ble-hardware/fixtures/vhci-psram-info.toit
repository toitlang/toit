// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import system
import .vhci-info as fixture

main:
  before := system.process-stats --gc
  // This lab board has 2 MB PSRAM. Internal SRAM cannot satisfy this bound.
  if before[system.STATS-INDEX-SYSTEM-FREE-MEMORY] < 1_000_000: throw "PSRAM_NOT_IN_USE"
  retained := List 128: | index/int | ByteArray 128 --initial=index
  fixture.main
  retained.size.repeat: | index/int |
    if retained[index] != (ByteArray 128 --initial=index): throw "RETAINED_VALUE_CHANGED"
  after := system.process-stats --gc
  full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
  if full-gcs < 20: throw "GC_COUNT_DID_NOT_ADVANCE"
  print "VHCI_PSRAM COMPLETE retained=$(retained.size) full-gcs=$full-gcs free=$(after[system.STATS-INDEX-SYSTEM-FREE-MEMORY])"
