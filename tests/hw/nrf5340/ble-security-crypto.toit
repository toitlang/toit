// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import ...crypto-test as crypto-tests
import .ble-nrf5340 as radio-tests

main:
  test-crypto
  print "NRF5340 Toit crypto before Bluetooth PASS"
  radio-tests.main
  // The radio test leaves an advertiser and a background scan alive. Run
  // the crypto checks again while the shared PSA-backed host is live.
  test-crypto
  print "NRF5340 SHARED CRYPTO PASS"

test-crypto:
  // Keep the exhaustive pure-Toit Hamming and MD5 sweeps in the separate
  // ble-security-crypto-exhaustive program. They do not use the shared native
  // provider and the MD5 sweep takes many minutes on this board. HMAC below
  // still checks MD5 known answers alongside the native hash algorithms.
  crypto-tests.hex-test
  crypto-tests.hash-test
  crypto-tests.chacha-test
  crypto-tests.sip-test
  crypto-tests.aead-simple-test
  crypto-tests.adler-test
  crypto-tests.blake-test
  crypto-tests.hmac-test
  crypto-tests.random-test
