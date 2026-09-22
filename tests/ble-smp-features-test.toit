// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.smp-features as smp
import expect show *
import system

main:
  owned := #[1, 1, 0, 0x0d, 16, 3, 3]
  features := smp.Features owned
  owned[1] = 3
  expect-equals 1 features.io-capability
  expect features.bonding
  expect-equals #[0x0d, 0, 1] features.check-iocap
  copy := features.packet
  copy[3] = 0
  system.process-stats --gc
  expect features.secure-connections
  // Exhaust the 25 SC IO combinations, independently enumerated from Table 2.8.
  matrix := [
    ["fail", "fail", "passkey-entry", "fail", "passkey-entry"],
    ["fail", "numeric-comparison", "passkey-entry", "fail", "numeric-comparison"],
    ["passkey-entry", "passkey-entry", "passkey-entry", "fail", "passkey-entry"],
    ["fail", "fail", "fail", "fail", "fail"],
    ["passkey-entry", "numeric-comparison", "passkey-entry", "fail", "numeric-comparison"],
  ]
  5.repeat: | a/int |
    5.repeat: | b/int |
      request := smp.Features #[1, a, 0, 0x0c, 16, 0, 0]
      response := smp.Features #[2, b, 0, 8, 16, 0, 0] --response
      expected := matrix[a][b]
      if expected == "fail":
        fails 3: smp.select-association request response --require-authentication
      else:
        expect-equals expected (smp.select-association request response --require-authentication)
      // The responder alone may request MITM; the same table still applies.
      reverse-request := smp.Features #[1, a, 0, 8, 16, 0, 0]
      reverse-response := smp.Features #[2, b, 0, 0x0c, 16, 0, 0] --response
      if expected == "fail":
        expect-equals "just-works"
            smp.select-association reverse-request reverse-response --no-require-authentication
      else:
        expect-equals expected
            smp.select-association reverse-request reverse-response --no-require-authentication
      // Neither exchanged MITM bit means Just Works, even with capable displays.
      plain := smp.Features #[1, a, 0, 8, 16, 0, 0]
      expect-equals "just-works" (smp.select-association plain response --no-require-authentication)
      fails 3: smp.select-association plain response --require-authentication
  request := smp.Features #[1, 1, 0, 0x0c, 16, 3, 3]
  [
    [#[2, 1, 0, 4, 16, 0, 0], 3],
    [#[2, 1, 0, 0x0c, 15, 0, 0], 6],
    [#[2, 1, 1, 0x0c, 16, 0, 0], 2],
    [#[2, 1, 0, 0x0c, 16, 8, 0], 0x0a],
  ].do: | entry/List |
    response := smp.Features entry[0] --response
    fails entry[1]: smp.select-association request response --require-authentication
  [
    #[], #[1, 1, 0, 8, 16, 0], #[2, 1, 0, 8, 16, 0, 0],
    #[1, 5, 0, 8, 16, 0, 0], #[1, 1, 2, 8, 16, 0, 0],
    #[1, 1, 0, 0x0a, 16, 0, 0], #[1, 1, 0, 8, 6, 0, 0],
    #[1, 1, 0, 8, 17, 0, 0],
  ].do: | bytes/ByteArray | fails 0x0a: smp.Features bytes
  // Preserve AuthReq for the check, while ignoring RFU/obsolete distribution bits.
  response := smp.Features #[2, 1, 0, 0xcc, 16, 0xf7, 0xf7] --response
  expect-equals 2 response.initiator-keys
  expect-equals #[0xcc, 0, 1] response.check-iocap
  expect-equals "numeric-comparison" (smp.select-association request response --require-authentication)

fails reason/int [body]:
  error := catch: body.call
  expect (error is smp.PairingError and error.reason == reason)
