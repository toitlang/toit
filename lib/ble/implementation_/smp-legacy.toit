// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto
import crypto.aes
import .security-state show SecurityState
import .smp-features show PairingError

/**
LE legacy pairing (without Secure Connections): its key functions and keys.

$c1 and $s1 are the confirm and short term key functions that the pairing
  engine (`smp-pairing`) uses for a legacy exchange; both build on $e, the
  AES-128 block function. $LegacyKey is a long term key with the EDIV and
  Rand a peer presents to ask for it, distributed after encryption; $LegacyKeyReceiver
  collects the one the peer distributes. The distribution exchange
  (`smp-distribution`) orders that traffic and bond records (`bond`) keep
  the keys for resumption.

All inputs and outputs are in the order the values travel on the air: SMP
  PDUs as transmitted (opcode first), addresses least significant byte first,
  and 128-bit values least significant byte first. The AES block function
  works on the big-endian representation, so the helpers reverse around it.
*/

// The functions are those of Core 6.3 Vol 3 Part H 2.2.3 (c1) and 2.2.4 (s1);
// the key PDUs are Encryption Information and Central Identification
// (3.6.2 and 3.6.3).

/** e(k, p): AES-128 of the 128-bit value $p under $k, both least significant byte first. */
e k/ByteArray p/ByteArray -> ByteArray:
  if k.size != 16 or p.size != 16: throw "INVALID_ARGUMENT"
  return reverse_ ((aes.AesEcb.encryptor (reverse_ k)).encrypt (reverse_ p))

/**
c1: the confirm value over the pairing exchange.

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

/** s1: the short term key from the two pairing randoms. */
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

/**
A legacy long term key with the identifiers a peer presents to ask for it
  (distributed as Encryption Information and Central Identification).

$ltk is the 128-bit key least significant byte first as distributed; $key
  returns it in the big-endian order the encryption commands take.
*/
class LegacyKey:
  ltk/ByteArray
  ediv/int
  rand/ByteArray

  constructor .ltk .ediv .rand:
    if ltk.size != 16 or not 0 <= ediv <= 0xffff or rand.size != 8: throw "INVALID_ARGUMENT"

  /** Creates a fresh key to distribute. */
  constructor.random:
    ltk = crypto.random --size=16
    random := crypto.random --size=2
    ediv = random[0] | (random[1] << 8)
    rand = crypto.random --size=8

  /** Returns the key in big-endian cryptographic order. */
  key -> ByteArray: return reverse_ ltk

  /** Encodes the ordered pair only while this connection has its new encryption key. */
  packets security/SecurityState -> List:
    if not security.paired or not security.encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"
    return [#[6] + ltk, #[7, ediv & 0xff, ediv >> 8] + rand]

/** Collects one distributed legacy key, withholding partial results. */
class LegacyKeyReceiver:
  security_/SecurityState
  pending_/ByteArray? := null
  key_/LegacyKey? := null
  closed_/bool := false

  constructor .security_:

  /** Accepts Encryption Information followed by Central Identification. */
  receive packet/ByteArray -> none:
    if closed_: throw "SMP_IDENTITY_CLOSED"
    succeeded := false
    try:
      if not security_.paired or not security_.encrypted: throw "SMP_IDENTITY_NOT_ENCRYPTED"
      if key_: throw (PairingError 0x0a)
      if not pending_:
        if packet.size != 17 or packet[0] != 6: throw (PairingError 0x0a)
        pending_ = packet[1..].copy
      else:
        if packet.size != 11 or packet[0] != 7: throw (PairingError 0x0a)
        key_ = LegacyKey pending_ (packet[1] | (packet[2] << 8)) packet[3..].copy
        pending_ = null
      succeeded = true
    finally:
      if not succeeded: close

  /** Returns the complete key, or null while pending. */
  key -> LegacyKey?:
    if closed_: throw "SMP_IDENTITY_CLOSED"
    return key_

  close -> none:
    closed_ = true
    pending_ = null
    key_ = null
