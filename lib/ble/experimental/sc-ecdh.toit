// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
P-256 key agreement for LE Secure Connections.

Public keys use SMP's 64-byte X-then-Y representation: each coordinate is little
  endian. DHKey output is 32-byte big endian for the sc-crypto derivation functions.
  Point validation and scalar multiplication use the SDK's mbedTLS primitive.
  The published Bluetooth debug public key is rejected. This module does not
  implement pairing state or authenticate the remote public key.
*/

import crypto.ec as ec

// DER SubjectPublicKeyInfo: id-ecPublicKey, prime256v1, uncompressed point.
PUBLIC-PREFIX_ ::= #[0x30, 0x59, 0x30, 0x13, 6, 7, 0x2a, 0x86, 0x48,
                    0xce, 0x3d, 2, 1, 6, 8, 0x2a, 0x86, 0x48, 0xce,
                    0x3d, 3, 1, 7, 3, 0x42, 0, 4]
DEBUG-X_ ::= #[0x20, 0xb0, 3, 0xd2, 0xf2, 0x97, 0xbe, 0x2c,
              0x5e, 0x2c, 0x83, 0xa7, 0xe9, 0xf9, 0xa5, 0xb9,
              0xef, 0xf4, 0x91, 0x11, 0xac, 0xf4, 0xfd, 0xdb,
              0xcc, 3, 1, 0x48, 0x0e, 0x35, 0x9d, 0xe6]
DEBUG-Y_ ::= #[0xdc, 0x80, 0x9c, 0x49, 0x65, 0x2a, 0xeb, 0x6d,
              0x63, 0x32, 0x9a, 0xbf, 0x5a, 0x52, 0x15, 0x5c,
              0x76, 0x63, 0x45, 0xc2, 0x8f, 0xed, 0x30, 0x24,
              0x74, 0x1c, 0x8e, 0xd0, 0x15, 0x89, 0xd2, 0x8b]

/** Generates a fresh P-256 key pair using the SDK RNG, with managed DER copies. */
generate -> ec.EcKeyPair:
  pair := ec.EcKeyPair.generate --curve=ec.EcKey.CURVE-SECP256R1
  return ec.EcKeyPair
      (ec.EcKey.internal_ pair.private-key.der.copy true)
      (ec.EcKey.internal_ pair.public-key.der.copy false)

/** Exports a P-256 public key into owned SMP coordinate bytes. */
public-key key/ec.EcKey -> ByteArray:
  der := key.der
  if key.is-private or der.size != 91 or der[..27] != PUBLIC-PREFIX_:
    throw "SMP_INVALID_PUBLIC_KEY"
  bytes := ByteArray 64
  32.repeat: | index/int |
    bytes[index] = der[58 - index]
    bytes[32 + index] = der[90 - index]
  return bytes

/** Computes an owned big-endian DHKey, rejecting invalid or debug peer points. */
dhkey private-key/ec.EcKey peer-public/ByteArray -> ByteArray:
  if peer-public.size != 64 or not private-key.is-private: throw "SMP_INVALID_PUBLIC_KEY"
  der := ByteArray 91
  der.replace 0 PUBLIC-PREFIX_
  32.repeat: | index/int |
    der[27 + index] = peer-public[31 - index]
    der[59 + index] = peer-public[63 - index]
  if der[27..59] == DEBUG-X_ and der[59..] == DEBUG-Y_:
    throw "SMP_DEBUG_KEY_REJECTED"
  // mbedTLS rejects out-of-range/off-curve points during parsing or multiplication.
  // Normalize only its point-validation error. Allocation and other runtime
  // failures must not become peer protocol errors.
  shared/ByteArray? := null
  error := catch:
    peer := ec.EcKey.parse-public der
    shared = private-key.compute-shared-secret peer
  if error == "ECP - Invalid private or public key": throw "SMP_INVALID_PUBLIC_KEY"
  if error: throw error
  if shared.size != 32: throw "SMP_INVALID_DHKEY"
  return shared.copy
