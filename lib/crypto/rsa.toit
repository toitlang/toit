// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .crypto
import ..io as io

/**
Support for RSA (Rivest–Shamir–Adleman) public-key cryptography.

See https://en.wikipedia.org/wiki/RSA_cryptosystem.

This implementation uses native primitives.
*/

class RsaKey:
  rsa-key_ := ?

  constructor.private_ key/io.Data password/string?="":
    rsa-key_ = rsa-parse-private-key_ resource-freeing-module_ key password

  constructor.public_ key/io.Data:
    rsa-key_ = rsa-parse-public-key_ resource-freeing-module_ key

  /**
  Parses a PKCS#1 or PKCS#8 encoded private key.
  The $key must be a byte array (DER or PEM) or string (PEM).
  The $password is optional and used for encrypted keys.
  */
  static parse-private key/io.Data --password/string?="" -> RsaKey:
    return RsaKey.private_ key password

  /**
  Parses a PKCS#1 or X.509 encoded public key.
  The $key must be a byte array (DER) or string (PEM).
  */
  static parse-public key/io.Data -> RsaKey:
    return RsaKey.public_ key

  /**
  Signs the $digest with this private key.
  $digest must be the hash of the message to sign.
  Supported hash lengths: 20 (SHA-1), 32 (SHA-256), 48 (SHA-384), 64 (SHA-512).
  */
  sign digest/io.Data -> ByteArray:
    return rsa-sign_ rsa-key_ digest

  /**
  Verifies the $signature of the $digest with this public key.
  $digest must be the hash of the message that was signed.
  Returns true if the signature is valid, false otherwise.
  */
  verify digest/io.Data signature/io.Data -> bool:
    return rsa-verify_ rsa-key_ digest signature

rsa-parse-private-key_ group key/io.Data password/string? -> any:
  #primitive.crypto.rsa-parse-private-key:
    return io.primitive-redo-io-data_ it key: | bytes |
      rsa-parse-private-key_ group bytes password

rsa-parse-public-key_ group key/io.Data -> any:
  #primitive.crypto.rsa-parse-public-key:
    return io.primitive-redo-io-data_ it key: | bytes |
      rsa-parse-public-key_ group bytes

rsa-sign_ rsa digest/io.Data -> ByteArray:
  #primitive.crypto.rsa-sign:
    return io.primitive-redo-io-data_ it digest: | bytes |
      rsa-sign_ rsa bytes

rsa-verify_ rsa digest/io.Data signature/io.Data -> bool:
  #primitive.crypto.rsa-verify:
    return io.primitive-redo-io-data_ it digest: | bytes |
      rsa-verify_ rsa bytes signature
    io.primitive-redo-io-data_ it signature: | bytes |
      rsa-verify_ rsa digest bytes

