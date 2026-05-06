// Copyright (C) 2026 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .sha
import .sha1
import ..io as io
import encoding.base64

/**
Support for Elliptic Curve (EC) public-key cryptography.

EC can be used for digital signatures (ECDSA) and key agreement (ECDH).

# Examples

## Signing and Verifying
```
import crypto.ec

// Assuming 'private-key' and 'public-key' are available as ec.EcKey.

message := "Hello world"
key := ec.EcKeyPair.generate --curve="secp256r1"
signature := key.sign message

if key.verify message signature:
  print "Signature is valid"
else:
  print "Signature is invalid"
```
*/

/**
A pair of EC keys generated together.
*/
class EcKeyPair:
  private-key/EcKey
  public-key/EcKey

  constructor .private-key .public-key:

  /** See $EcKey.sign. */
  sign message/io.Data --hash/int=EcKey.SHA-256 -> ByteArray:
    return private-key.sign message --hash=hash

  /** See $EcKey.verify. */
  verify message/io.Data signature/ByteArray --hash/int=EcKey.SHA-256 -> bool:
    return public-key.verify message signature --hash=hash

  /**
  Generates a new EC key pair for the given $curve.
  Common curves: "secp256r1", "secp384r1", "secp521r1".
  */
  static generate --curve/string="secp256r1" -> EcKeyPair:
    pair := ec-generate-key_ curve
    return EcKeyPair
        EcKey.internal_ pair[0] true
        EcKey.internal_ pair[1] false

class EcKey:
  /** Produces a 20-byte digest. */
  static SHA-1 ::= 1
  /** Default. Produces a 32-byte digest. */
  static SHA-256 ::= 256
  /** Produces a 48-byte digest. */
  static SHA-384 ::= 384
  /** Produces a 64-byte digest. */
  static SHA-512 ::= 512

  /**
  The DER-encoded key bytes.
  */
  der/ByteArray
  is-private/bool

  /** The size of the key DER in bytes. */
  size -> int: return der.size

  constructor.internal_ .der .is-private:

  /**
  Parses an EC private key and stores it as DER.
  The $key must be DER or PEM.
  The $password is optional and used for encrypted keys.
  */
  static parse-private key/io.Data --password/string?="" -> EcKey:
    der := ec-get-private-key-der_ key (password or "")
    return EcKey.internal_ der true

  /**
  Parses an EC public key and stores it as DER.
  The $key must be DER or PEM.
  */
  static parse-public key/io.Data -> EcKey:
    der := ec-get-public-key-der_ key
    return EcKey.internal_ der false

  /**
  Signs the $message with this private key.
  */
  sign message/io.Data --hash/int=SHA-256 -> ByteArray:
    digest := compute-digest_ message hash
    return sign-digest digest --hash=hash

  /**
  Signs the $digest with this private key.
  */
  sign-digest digest/ByteArray --hash/int -> ByteArray:
    check-digest-length_ digest hash
    return ec-sign_ der digest hash

  /**
  Verifies the $signature of the $message with this public key.
  */
  verify message/io.Data signature/ByteArray --hash/int=SHA-256 -> bool:
    digest := compute-digest_ message hash
    return verify-digest digest signature --hash=hash

  /**
  Verifies the $signature of the $digest with this public key.
  */
  verify-digest digest/ByteArray signature/ByteArray --hash/int -> bool:
    check-digest-length_ digest hash
    return ec-verify_ der digest signature hash

  /**
  Exports this key in PEM format.
  */
  to-pem -> string:
    return der-to-pem_ der --is-private=is-private

  static check-digest-length_ digest/ByteArray hash/int:
    expected-length := 0
    if hash == SHA-256: expected-length = 32
    else if hash == SHA-1: expected-length = 20
    else if hash == SHA-384: expected-length = 48
    else if hash == SHA-512: expected-length = 64
    else: throw "INVALID_ARGUMENT"

    if digest.size != expected-length: throw "INVALID_ARGUMENT"

  static compute-digest_ message/io.Data hash/int -> ByteArray:
    if hash == SHA-256: return sha256 message
    else if hash == SHA-1: return sha1 message
    else if hash == SHA-384: return sha384 message
    else if hash == SHA-512: return sha512 message
    throw "INVALID_ARGUMENT"

  static der-to-pem_ der/ByteArray --is-private/bool -> string:
    header := is-private ? "-----BEGIN EC PRIVATE KEY-----" : "-----BEGIN PUBLIC KEY-----"
    footer := is-private ? "-----END EC PRIVATE KEY-----" : "-----END PUBLIC KEY-----"

    b64 := base64.encode der
    lines := [header]
    i := 0
    while i < b64.size:
      lines.add b64[i .. min (i + 64) b64.size]
      i += 64
    lines.add footer

    return lines.join "\n"

// Primitives

ec-generate-key_ curve/string -> List:
  #primitive.crypto.ec-generate-key

ec-sign_ private-key-der/ByteArray digest/io.Data hash/int -> ByteArray:
  #primitive.crypto.ec-sign

ec-verify_ public-key-der/ByteArray digest/ByteArray signature/ByteArray hash/int -> bool:
  #primitive.crypto.ec-verify

ec-get-private-key-der_ key/io.Data password/string -> ByteArray:
  #primitive.crypto.ec-get-private-key-der:
    return io.primitive-redo-io-data_ it key: | bytes |
      ec-get-private-key-der_ bytes password

ec-get-public-key-der_ key/io.Data -> ByteArray:
  #primitive.crypto.ec-get-public-key-der:
    return io.primitive-redo-io-data_ it key: | bytes |
      ec-get-public-key-der_ bytes
