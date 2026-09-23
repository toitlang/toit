// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Legacy pairing primitives against the sample data of Core 6.3 Vol 3 Part H
// Appendix D.

import encoding.hex
import expect show *
import ble.experimental.smp-legacy as legacy

// The appendix writes values most significant byte first.
le hex-string/string -> ByteArray:
  bytes := hex.decode hex-string
  return ByteArray bytes.size: bytes[bytes.size - 1 - it]

main:
  k := ByteArray 16
  // D.2: c1.
  r := le "5783D52156AD6F0E6388274EC6702EE0"
  preq := le "07071000000101"
  pres := le "05000800000302"
  ia := le "A1A2A3A4A5A6"
  ra := le "B1B2B3B4B5B6"
  expect-equals (le "1e1e3fef878988ead2a74dc5bef13b86") (legacy.c1 k r preq pres 1 ia 0 ra)
  // D.3: s1.
  r1 := le "000F0E0D0C0B0A091122334455667788"
  r2 := le "010203040506070899AABBCCDDEEFF00"
  expect-equals (le "9a1fe1f0e8b0f49b5b4216ae796da062") (legacy.s1 k r1 r2)
  // D.1: e with the AES-128 FIPS-197 sample, key and plaintext most significant byte first.
  expect-equals (le "3ad77bb40d7a3660a89ecaf32466ef97")
      (legacy.e (le "2b7e151628aed2a6abf7158809cf4f3c") (le "6bc1bee22e409f96e93d7e117393172a"))
  expect-throw "INVALID_ARGUMENT": legacy.s1 k r1 #[1]
  expect-throw "INVALID_ARGUMENT": legacy.c1 k r preq pres 2 ia 0 ra
