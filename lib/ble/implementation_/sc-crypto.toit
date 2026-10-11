// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.cmac show cmac
import crypto.compare show constant-time-equals
import io

/**
The key derivation functions of LE Secure Connections pairing.

$f4 computes a confirm value, $f5 derives the MacKey and LTK ($Keys) from
  the shared Diffie-Hellman secret, $f6 computes the DHKey check and $g2
  the Numeric Comparison number; $verify-check compares two check values in
  constant time. They are AES-CMAC constructions over the SDK's `crypto.cmac`
  and are used by the pairing engine (`smp-pairing`), which owns the exchange.

All multi-octet inputs and outputs use most-significant-octet-first order,
  like the standard test vectors and the crypto library. SMP little-endian
  public coordinates, nonces, and checks require conversion at the wire boundary.
  An address is seven bytes: public/random type (0/1), then the six address bytes
  most significant first. IO capabilities are AuthReq, OOB flag, IO capability,
  in that order. These functions do not perform pairing or authenticate a peer.
*/

// The functions follow Core 6.3 Vol 3 Part H, 2.2.6 to 2.2.9; the tests use
// the Appendix D sample data.

/** Derived keys with separate owned storage. */
class Keys:
  mac-key/ByteArray
  ltk/ByteArray

  constructor .mac-key .ltk:

/** Computes f4 from two 32-byte X coordinates, a 16-byte nonce, and one octet. */
f4 u/ByteArray v/ByteArray x/ByteArray z/int -> ByteArray:
  size_ u 32
  size_ v 32
  size_ x 16
  if not 0 <= z <= 255: throw "INVALID_ARGUMENT"
  message := ByteArray 65
  message.replace 0 u
  message.replace 32 v
  message[64] = z
  return cmac --key=x message

/** Derives MacKey and LTK with f5 from a 32-byte DHKey and connection context. */
f5 w/ByteArray n1/ByteArray n2/ByteArray a1/ByteArray a2/ByteArray -> Keys:
  size_ w 32
  size_ n1 16
  size_ n2 16
  address_ a1
  address_ a2
  salt := #[0x6c, 0x88, 0x83, 0x91, 0xaa, 0xf5, 0xa5, 0x38,
            0x60, 0x37, 0x0b, 0xdb, 0x5a, 0x60, 0x83, 0xbe]
  key := cmac --key=salt w
  message := ByteArray 53
  message.replace 1 #[0x62, 0x74, 0x6c, 0x65]
  message.replace 5 n1
  message.replace 21 n2
  message.replace 37 a1
  message.replace 44 a2
  message[51] = 1  // Length is 0x0100 bits, most significant octet first.
  mac-key := cmac --key=key message
  message[0] = 1
  ltk := cmac --key=key message
  return Keys mac-key ltk

/** Computes the f6 DHKey check using 16-byte key, nonces, and R. */
f6 w/ByteArray n1/ByteArray n2/ByteArray r/ByteArray iocap/ByteArray
    a1/ByteArray a2/ByteArray -> ByteArray:
  size_ w 16
  size_ n1 16
  size_ n2 16
  size_ r 16
  size_ iocap 3
  address_ a1
  address_ a2
  message := ByteArray 65
  message.replace 0 n1
  message.replace 16 n2
  message.replace 32 r
  message.replace 48 iocap
  message.replace 51 a1
  message.replace 58 a2
  return cmac --key=w message

/** Returns g2's unsigned 32-bit result; numeric comparison uses it modulo 1000000. */
g2 u/ByteArray v/ByteArray x/ByteArray y/ByteArray -> int:
  size_ u 32
  size_ v 32
  size_ x 16
  size_ y 16
  message := ByteArray 80
  message.replace 0 u
  message.replace 32 v
  message.replace 64 y
  digest := cmac --key=x message
  return io.BIG-ENDIAN.uint32 digest 12

/** Compares two fixed-width confirmation or DHKey-check values without an early exit. */
verify-check expected/ByteArray received/ByteArray -> bool:
  size_ expected 16
  size_ received 16
  return constant-time-equals expected received

size_ bytes/ByteArray expected/int -> none:
  if bytes.size != expected: throw "INVALID_ARGUMENT"

address_ bytes/ByteArray -> none:
  size_ bytes 7
  if bytes[0] > 1: throw "INVALID_ARGUMENT"
