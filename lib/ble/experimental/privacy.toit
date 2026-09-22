// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

/**
Resolvable private address arithmetic (Core 6.3 Vol 3 Part H 2.2.2 and Vol 6 Part B 1.3.2).

IRKs and prand use most-significant-octet-first order, like the specification's
  cryptographic vectors. Generated and resolved addresses use six-byte HCI wire
  order, least significant octet first. Results own their managed storage.

Resolution is a 24-bit hash match, not authentication or unique identity proof.
  This module does not store keys, rotate controller addresses, or enable privacy
  in scanning, advertising, connection creation, or pairing.
*/

import crypto
import crypto.aes show AesEcb
import crypto.compare show constant-time-equals

/** Computes the three-byte ah hash, in most-significant-octet-first order. */
ah irk/ByteArray prand/ByteArray -> ByteArray:
  if irk.size != 16 or prand.size != 3: throw "INVALID_ARGUMENT"
  block := ByteArray 16
  block.replace 13 prand
  cipher := AesEcb.encryptor irk
  try:
    return (cipher.encrypt block)[13..].copy
  finally:
    cipher.close

/**
Builds an address from an IRK and a valid, most-significant-first prand.

The two high bits must be 01. The other 22 bits must contain both zero and one.
  Use $generate for fresh cryptographic randomness; this function supports
  deterministic address construction and test vectors.
*/
from-prand irk/ByteArray prand/ByteArray -> ByteArray:
  if not (valid-prand_ prand): throw "INVALID_ARGUMENT"
  hash := ah irk prand
  return #[hash[2], hash[1], hash[0], prand[2], prand[1], prand[0]]

/** Generates a fresh address with the SDK's cryptographic random source. */
generate irk/ByteArray -> ByteArray:
  if irk.size != 16: throw "INVALID_ARGUMENT"
  while true:
    prand := crypto.random --size=3
    prand[0] = (prand[0] & 0x3f) | 0x40
    if valid-prand_ prand: return from-prand irk prand

/**
Checks a random address against one IRK, without retaining either input.

$address-type is the HCI address type, 0 through 3. Public addresses and resolved
  identity addresses return false, as do non-resolvable, static, reserved, or
  malformed random-address patterns. Invalid buffer sizes or types throw.
*/
resolves irk/ByteArray address/ByteArray address-type/int -> bool:
  if irk.size != 16 or address.size != 6 or not 0 <= address-type <= 3:
    throw "INVALID_ARGUMENT"
  if address-type != 1: return false
  prand := #[address[5], address[4], address[3]]
  if not (valid-prand_ prand): return false
  return constant-time-equals (ah irk prand) #[address[2], address[1], address[0]]

valid-prand_ prand/ByteArray -> bool:
  if prand.size != 3 or (prand[0] & 0xc0) != 0x40: return false
  random-part := ((prand[0] & 0x3f) << 16) | (prand[1] << 8) | prand[2]
  return random-part != 0 and random-part != 0x3f_ffff
