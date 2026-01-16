// Copyright (C) 2026 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .crypto

class RsaKey:
  rsa_key_ := ?

  constructor.private_ key/ByteArray password/string?="":
    rsa_key_ = rsa_parse_private_key_ resource-freeing-module_ key password

  constructor.public_ key/ByteArray:
    rsa_key_ = rsa_parse_public_key_ resource-freeing-module_ key

  /**
  Parses a PKCS#1 or PKCS#8 encoded private key.
  The $key must be a byte array (DER or PEM).
  The $password is optional and used for encrypted keys.
  */
  static parse_private_key key/ByteArray --password/string?="" -> RsaKey:
    return RsaKey.private_ key password

  /**
  Parses a PKCS#1 or X.509 encoded public key.
  The $key must be a byte array (DER or PEM).
  */
  static parse_public_key key/ByteArray -> RsaKey:
    return RsaKey.public_ key

  /**
  Signs the $digest with this private key.
  $digest must be the hash of the message to sign.
  Supported hash lengths: 20 (SHA-1), 32 (SHA-256), 48 (SHA-384), 64 (SHA-512).
  */
  sign digest/ByteArray -> ByteArray:
    return rsa_sign_ rsa_key_ digest

  /**
  Verifies the $signature of the $digest with this public key.
  $digest must be the hash of the message that was signed.
  Returns true if the signature is valid, false otherwise.
  */
  verify digest/ByteArray signature/ByteArray -> bool:
    return rsa_verify_ rsa_key_ digest signature

rsa_parse_private_key_ group key/ByteArray password/string? -> any:
  #primitive.crypto.rsa_parse_private_key

rsa_parse_public_key_ group key/ByteArray -> any:
  #primitive.crypto.rsa_parse_public_key

rsa_sign_ rsa digest/ByteArray -> ByteArray:
  #primitive.crypto.rsa_sign

rsa_verify_ rsa digest/ByteArray signature/ByteArray -> bool:
  #primitive.crypto.rsa_verify
