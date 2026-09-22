// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.privacy as privacy
import encoding.hex
import expect show *
import system

main:
  // Public Core 6.3 Vol 3 Part H Appendix D.7 vector, printed MSB first.
  irk := hex.decode "ec0234a357c8ad05341010a60a397d9b"
  prand := hex.decode "708194"
  expected := hex.decode "aafb0d948170"
  hash := privacy.ah irk prand
  expect-equals (hex.decode "0dfbaa") hash
  address := privacy.from-prand irk prand
  expect-equals expected address
  expect (privacy.resolves irk address 1)
  [0, 2, 3].do: expect (not (privacy.resolves irk address it))
  24.repeat: | bit/int |
    changed := address.copy
    changed[bit / 8] ^= 1 << (bit % 8)
    expect (not (privacy.resolves irk changed 1))
  wrong-key := irk.copy
  wrong-key[0] ^= 1
  expect (not (privacy.resolves wrong-key address 1))
  // Reject non-RPA patterns and the two forbidden random portions.
  [#[0, 0, 1], #[0x80, 0, 1], #[0xc0, 0, 1], #[0x40, 0, 0], #[0x7f, 0xff, 0xff]].do: | invalid-prand/ByteArray |
    expect-throw "INVALID_ARGUMENT": privacy.from-prand irk invalid-prand
    invalid := #[0, 0, 0, invalid-prand[2], invalid-prand[1], invalid-prand[0]]
    expect (not (privacy.resolves irk invalid 1))
  [#[0x40, 0, 1], #[0x7f, 0xff, 0xfe]].do:
    expect (privacy.resolves irk (privacy.from-prand irk it) 1)
  expect-throw "INVALID_ARGUMENT": privacy.ah (ByteArray 15) prand
  expect-throw "INVALID_ARGUMENT": privacy.ah irk (ByteArray 4)
  expect-throw "INVALID_ARGUMENT": privacy.generate (ByteArray 17)
  expect-throw "INVALID_ARGUMENT": privacy.from-prand irk (ByteArray 2)
  expect-throw "INVALID_ARGUMENT": privacy.resolves irk (ByteArray 5) 1
  expect-throw "INVALID_ARGUMENT": privacy.resolves irk address 4
  retained := []
  32.repeat:
    generated := privacy.generate irk
    expect-equals 6 generated.size
    expect-equals 0x40 (generated[5] & 0xc0)
    expect (privacy.resolves irk generated 1)
    retained.add generated
  copies := retained.map: it.copy
  prand.fill 0
  irk.fill 0
  system.process-stats --gc
  expect-equals expected address
  expect-equals (hex.decode "0dfbaa") hash
  retained.size.repeat: expect-equals copies[it] retained[it]
