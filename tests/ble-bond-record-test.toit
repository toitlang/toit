// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.smp-identity
import ble.experimental.smp-legacy show LegacyKey
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
  legacy key local peer

legacy key/ByteArray local/smp-identity.Identity peer/smp-identity.Identity:
  peer-key := LegacyKey (ByteArray 16 --initial=7) 0x1234 (ByteArray 8 --initial=8)
  local-key := LegacyKey.random
  expect-equals 16 local-key.ltk.size
  expect-equals 8 local-key.rand.size
  expect (local-key.key != local-key.ltk)
  expect-equals local-key.ltk[0] local-key.key[15]
  expect-throw "INVALID_ARGUMENT": LegacyKey (ByteArray 15) 0 (ByteArray 8)
  expect-throw "INVALID_ARGUMENT": LegacyKey (ByteArray 16) 0x10000 (ByteArray 8)
  expect-throw "INVALID_ARGUMENT": LegacyKey (ByteArray 16) 0 (ByteArray 7)
  sc := bond.Candidate key local peer --no-authenticated
  expect (not sc.legacy)
  [[peer-key, null], [null, local-key], [peer-key, local-key]].do: | pair/List |
    candidate := bond.Candidate key local peer --no-authenticated --peer-legacy=pair[0] --local-legacy=pair[1]
    expect candidate.legacy
    encoded := candidate.encode
    count := (pair[0] ? 1 : 0) + (pair[1] ? 1 : 0)
    expect-equals (67 + 26 * count) encoded.size
    expect-equals 2 encoded[2]
    expect-equals ((pair[0] ? 1 : 0) | (pair[1] ? 2 : 0)) encoded[66]
    if pair[0]:
      expect-equals peer-key.ltk encoded[67..83]
      expect-equals #[0x34, 0x12] encoded[83..85]
      expect-equals peer-key.rand encoded[85..93]
    decoded := bond.Candidate.decode encoded
    expect decoded.legacy
    expect-equals encoded decoded.encode
    expect-equals (pair[0] != null) (decoded.peer-legacy != null)
    expect-equals (pair[1] != null) (decoded.local-legacy != null)
    if pair[1]:
      expect-equals local-key.ltk decoded.local-legacy.ltk
      expect-equals local-key.ediv decoded.local-legacy.ediv
      expect-equals local-key.rand decoded.local-legacy.rand
    expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode encoded[..encoded.size - 1]
    expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode (encoded + #[0])
  // A version 2 record needs at least one key; a version 1 record has none.
  empty := (bond.Candidate key local peer --no-authenticated).encode + #[0]
  empty[2] = 2
  expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode empty
  bad-presence := (bond.Candidate key local peer --no-authenticated --peer-legacy=peer-key).encode
  bad-presence[66] = 4
  expect-throw "BLE_INVALID_BOND_RECORD": bond.Candidate.decode bad-presence
