// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.sc-ecdh as sc
import crypto.ec as ec
import encoding.hex as hex
import expect show *
import system

// Core 6.3 Vol 2 Part G, 7.1.2.2: public P-256 data set 2.
main:
  private-a := private-key "06a516693c9aa31a6084545d0c5db641b48572b97203ddffb7ac73f7d0457663"
  private-b := private-key "529aa0670d72cd6497502ed473502b037e8803b5c60829a5a3caa219505530ba"
  a := wire
      "2c31a47b5779809ef44cb5eaaf5c3e43d5f8faad4a8794cb987e9b03745c78dd"
      "919512183898dfbecd52e2408e43871fd021109117bd3ed4eaf8437743715d4f"
  b := wire
      "f465e43ff23d3f1b9dc7dfc04da8758184dbc966204796eccf0d6cf5e16500cc"
      "0201d048bcbbd899eeefc424164e33c201c2b010ca6b4d43a8a155cad8ecb279"
  expected := hex.decode "ab85843a2f6d883f62e5684b38e307335fe6e1945ecd19604105c6f23221eb69"
  a-copy := a.copy
  b-copy := b.copy
  shared := sc.dhkey private-a b
  expect-equals expected shared
  expect-equals expected (sc.dhkey private-b a)
  system.process-stats --gc
  expect-equals expected shared
  expect-equals a-copy a
  expect-equals b-copy b
  debug := wire
      "20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6"
      "dc809c49652aeb6d63329abf5a52155c766345c28fed3024741c8ed01589d28b"
  expect-throw "SMP_DEBUG_KEY_REJECTED": sc.dhkey private-b debug
  expect-throw "SMP_INVALID_PUBLIC_KEY": sc.dhkey private-a b[..63]
  expect-throw "SMP_INVALID_PUBLIC_KEY": sc.public-key private-a
  outside-field := wire
      "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
      "0201d048bcbbd899eeefc424164e33c201c2b010ca6b4d43a8a155cad8ecb279"
  mutated := b.copy
  mutated[32] ^= 1
  [ByteArray 64, (ByteArray 64 --initial=0xff), outside-field, mutated].do: | invalid/ByteArray |
    result/ByteArray? := null
    error := catch: result = sc.dhkey private-a invalid
    expect-equals "SMP_INVALID_PUBLIC_KEY" error
    expect-equals null result
  wrong-curve := ec.EcKeyPair.generate --curve=ec.EcKey.CURVE-SECP384R1
  expect-throw "SMP_INVALID_PUBLIC_KEY": sc.public-key wrong-curve.public-key
  expect-throw "INVALID_ARGUMENT": sc.dhkey wrong-curve.private-key b
  // A malformed peer must not poison the native context used by later calls.
  expect-equals expected (sc.dhkey private-a b)
  4.repeat:
    first := sc.generate
    second := sc.generate
    first-wire := sc.public-key first.public-key
    second-wire := sc.public-key second.public-key
    expect-equals 64 first-wire.size
    expect (first-wire != second-wire)
    secret := sc.dhkey first.private-key second-wire
    system.process-stats --gc
    expect-equals secret (sc.dhkey second.private-key first-wire)
    // Exported public coordinates are independent of the retained DER key.
    first-wire[0] ^= 1
    expect (first-wire != (sc.public-key first.public-key))

private-key scalar/string -> ec.EcKey:
  // Minimal SEC1 ECPrivateKey carrying the prime256v1 named-curve OID.
  der := (hex.decode "30310201010420") + (hex.decode scalar) +
      (hex.decode "a00a06082a8648ce3d030107")
  return ec.EcKey.parse-private der

wire x/string y/string -> ByteArray:
  big-x := hex.decode x
  big-y := hex.decode y
  result := ByteArray 64
  32.repeat: | index/int |
    result[index] = big-x[31 - index]
    result[32 + index] = big-y[31 - index]
  return result
