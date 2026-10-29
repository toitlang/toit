// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ...crypto-test as crypto-tests
import .ble-nrf5340 as radio-tests

main:
  crypto-tests.main
  print "NRF5340 Toit crypto before Bluetooth PASS"
  radio-tests.main
  // The radio test leaves an advertiser and a background scan alive. Run
  // the existing crypto suite again while the shared PSA-backed host is live.
  crypto-tests.main
  print "NRF5340 SHARED CRYPTO PASS"
