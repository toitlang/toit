// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import system
import ...ble-sc-crypto-test as derivations
import ...ble-sc-ecdh-test as agreement
import ...crypto-compare-test as comparison

main:
  // Keep Bluetooth enabled for the ESP32 hardware RNG used by the EC primitive.
  controller := hci.Controller (esp32.Esp32Transport)
  try:
    hci.initialize controller
    before := system.process-stats --gc
    3.repeat: | round/int |
      started := Time.monotonic-us
      with-timeout --ms=60_000:
        derivations.main
        agreement.main
        comparison.main
      elapsed := Time.monotonic-us - started
      stats := system.process-stats --gc
      print "VHCI_CRYPTO round=$round elapsed-us=$elapsed live=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY])"
    after := system.process-stats --gc
    gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if gcs < 30: throw "CRYPTO_GC_COVERAGE_MISSING"
    print "VHCI_CRYPTO COMPLETE rounds=3 full-gcs=$gcs vectors=true invalid-points=true generated-agreement=true comparison=true"
  finally:
    controller.close
    controller.wait-closed
