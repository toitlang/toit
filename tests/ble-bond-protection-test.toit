// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-protection
import ble.experimental.smp-identity
import expect show *
import encoding.hex
import system

main:
  key := ByteArray 32: it
  protector := bond-protection.Protection key
  independent := bond-protection.Protection key
  key.fill 0xff
  local := smp-identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  peer := smp-identity.Identity (ByteArray 16 --initial=2) #[6, 5, 4, 3, 2, 1] 0
  candidate := bond.Candidate (ByteArray 16 --initial=3) local peer --authenticated
  context := "provider-1/peer-1".to-byte-array
  // Independently generated with Python cryptography AESGCM, public test key.
  known := hex.decode "54425301000102030405060708090a0b1340d71ac6e6c1188e429488b2ea7b6e80d58437f07a5d7f3c62e3841c6801b30011affdaec0139975a57eed8e822c3bec58628f58d4a1d83d95281b1ae1f7ecf23e31be7791c8e1a87b939529c0b5547451"
  expect-equals candidate.encode (independent.open known --context=context).encode
  // Valid authentication cannot make an unsupported inner record acceptable.
  invalid-record := hex.decode "544253010b0a0908070605040302010074bf5b13356b6e9efcbd997860ce241e8418b1ba131cbdb71cfe5f6ba4d2302af55a50380a661e4f312d15f5fa2e1d1dee600d74025608b87b5de41752852e559e1386703a2b9986be7593b87e955fdc58fc"
  expect-throw "BLE_INVALID_BOND_RECORD": independent.open invalid-record --context=context
  sealed := protector.seal candidate --context=context
  expect-equals 98 sealed.size
  expect-equals #[0x54, 0x42, 0x53, 1] sealed[..4]
  decoded := independent.open sealed --context=context
  expect-equals candidate.encode decoded.encode
  expect decoded.authenticated
  second := protector.seal candidate --context=context
  expect (sealed != second)
  expect-equals candidate.encode (independent.open second --context=context).encode
  system.process-stats --gc
  // Both a fresh load and an explicitly retained decoded value own their data.
  expect-equals candidate.encode (independent.open sealed --context=context).encode
  second.fill 0
  expect-equals candidate.encode decoded.encode
  sealed.size.repeat: | index/int |
    altered := sealed.copy
    altered[index] ^= 1
    expect-throw "BLE_INVALID_SEALED_BOND": independent.open altered --context=context
  expect-throw "BLE_INVALID_SEALED_BOND": independent.open sealed[..97] --context=context
  expect-throw "BLE_INVALID_SEALED_BOND": independent.open (sealed + #[0]) --context=context
  expect-throw "BLE_INVALID_SEALED_BOND": independent.open sealed --context="provider-1/peer-2".to-byte-array
  expect-throw "BLE_INVALID_SEALED_BOND": independent.open sealed --context="provider-2/peer-1".to-byte-array
  wrong := bond-protection.Protection (ByteArray 32 --initial=0xff)
  expect-throw "BLE_INVALID_SEALED_BOND": wrong.open sealed --context=context
  wrong.close
  // Authentication failure does not poison the protector or expose plaintext.
  expect-equals candidate.encode (independent.open sealed --context=context).encode
  [#[], ByteArray 129].do: | invalid/ByteArray |
    expect-throw "INVALID_ARGUMENT": protector.seal candidate --context=invalid
    expect-throw "INVALID_ARGUMENT": protector.open sealed --context=invalid
  expect-throw "INVALID_ARGUMENT": bond-protection.Protection (ByteArray 16)
  protector.close
  protector.close
  expect-throw "BLE_BOND_PROTECTION_CLOSED": protector.seal candidate --context=context
  expect-throw "BLE_BOND_PROTECTION_CLOSED": protector.open sealed --context=context
  independent.close
