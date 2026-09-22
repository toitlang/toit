// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import ..set-map-shrink-pressure-test as collections
import ..services-resource-close-pressure-test as resources
import ..ble-service-central-start-pressure-test as central

// The sole application on a dedicated board. Real heap exhaustion; scripted
// controller traffic for the surviving peripheral and replacement central.
main:
  // Keep the ballast index at 16 KiB across 32-bit device and 64-bit host VMs.
  slots := 16384 / system.BYTES-PER-WORD
  with-timeout --ms=300_000:
    print "DEVICE_SERVICE_CLEANUP_PRESSURE START heap=65536 slots=$slots word-bytes=$system.BYTES-PER-WORD"
    collections.run-all --heap-size=(64 * 1024) --slot-count=slots
    system.process-stats --gc
    print "DEVICE_SERVICE_CLEANUP_PRESSURE COLLECTIONS_COMPLETE cases=96"
    resources.run-all --heap-size=(64 * 1024) --slot-count=slots
    system.process-stats --gc
    print "DEVICE_SERVICE_CLEANUP_PRESSURE RESOURCES_COMPLETE cases=97"
    central.run-all --heap-size=(64 * 1024) --slot-count=slots
    print "DEVICE_SERVICE_CLEANUP_PRESSURE COMPLETE cases=290 survivor=true replacement=true"
