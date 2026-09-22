// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.smp-identity
import expect show *
import system

main:
  key := ByteArray 16: it
  local := smp-identity.Identity (ByteArray 16) #[1, 2, 3, 4, 5, 6] 0
  peer := smp-identity.Identity (ByteArray 16 --initial=42) #[6, 5, 4, 3, 2, 0xc1] 1
  [false, true].do: | authenticated/bool |
    candidate := bond.Candidate key local peer --authenticated=authenticated
    encoded := candidate.encode
    expect-equals 66 encoded.size
    expect-equals #[0x54, 0x42, 1, authenticated ? 1 : 0] encoded[..4]
    expect-equals key encoded[4..20]
    expect-equals #[0, 1, 2, 3, 4, 5, 6] encoded[20..27]
    expect-equals #[1, 6, 5, 4, 3, 2, 0xc1] encoded[43..50]
    decoded := bond.Candidate.decode encoded
    encoded.fill 0
    system.process-stats --gc
    expect-equals candidate.encode decoded.encode
    expect-equals authenticated decoded.authenticated
    expect (not decoded.local.has-resolving-key)
    expect decoded.peer.has-resolving-key
    key-copy := decoded.key
    key-copy.fill 0xff
    expect-equals key decoded.key
    [0, 1, 2, 3, 20, 43].do: | index/int |
      invalid := candidate.encode
      invalid[index] = 0xff
      expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode invalid
    invalid := candidate.encode
    invalid[49] = 0x41
    expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode invalid
    expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode candidate.encode[..65]
    expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode (candidate.encode + #[0])
  owned := bond.Candidate key local peer --no-authenticated
  key.fill 99
  expect-equals 0 owned.key[0]
  expect-throw "INVALID_ARGUMENT": bond.Candidate #[] local peer --no-authenticated
