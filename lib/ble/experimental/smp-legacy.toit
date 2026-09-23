// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
LE legacy pairing primitives (Core 6.3 Vol 3 Part H 2.2.3, 2.2.4).

All inputs and outputs are in the order the values travel on the air: SMP
  PDUs as transmitted (opcode first), addresses least significant byte first,
  and 128-bit values least significant byte first. The AES block function
  works on the big-endian representation, so the helpers reverse around it.
*/

import crypto.aes

/** e(k, p): AES-128 of the 128-bit value $p under $k, both least significant byte first. */
e k/ByteArray p/ByteArray -> ByteArray:
  if k.size != 16 or p.size != 16: throw "INVALID_ARGUMENT"
  return reverse_ ((aes.AesEcb.encryptor (reverse_ k)).encrypt (reverse_ p))

/**
c1: the confirm value over the pairing exchange (2.2.3).

$r is the 128-bit random, $preq and $pres the 7-byte Pairing Request and
  Response PDUs, $ia and $ra the initiating and responding 6-byte addresses
  with their types $iat and $rat (0 public, 1 random).
*/
c1 k/ByteArray r/ByteArray preq/ByteArray pres/ByteArray iat/int ia/ByteArray rat/int ra/ByteArray -> ByteArray:
  if r.size != 16 or preq.size != 7 or pres.size != 7 or ia.size != 6 or ra.size != 6 or
      not 0 <= iat <= 1 or not 0 <= rat <= 1:
    throw "INVALID_ARGUMENT"
  p1 := ByteArray 16
  p1[0] = iat
  p1[1] = rat
  p1.replace 2 preq
  p1.replace 9 pres
  p2 := ByteArray 16
  p2.replace 0 ra
  p2.replace 6 ia
  first := e k (xor_ r p1)
  return e k (xor_ first p2)

/** s1: the short term key from the two pairing randoms (2.2.4). */
s1 k/ByteArray r1/ByteArray r2/ByteArray -> ByteArray:
  if r1.size != 16 or r2.size != 16: throw "INVALID_ARGUMENT"
  // r' takes the least significant 64 bits of each random: r1's below r2's.
  combined := ByteArray 16
  combined.replace 0 r2[..8]
  combined.replace 8 r1[..8]
  return e k combined

xor_ a/ByteArray b/ByteArray -> ByteArray:
  return ByteArray a.size: a[it] ^ b[it]

reverse_ bytes/ByteArray -> ByteArray:
  return ByteArray bytes.size: bytes[bytes.size - 1 - it]
