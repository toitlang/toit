// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .sha
import .sha1
import ..io as io
import encoding.base64

/**
Support for RSA (Rivest–Shamir–Adleman) public-key cryptography.

See https://en.wikipedia.org/wiki/RSA_cryptosystem.

RSA can be used for both encryption, and digital signatures.

# Examples

## Signing and Verifying
```
import crypto.rsa

// Assuming 'private-key' and 'public-key' are available as rsa.RsaKey.

message := "Hello world"
key := rsa.RsaKey.generate --bits=2048
signature := key.sign message

if key.verify message signature:
  print "Signature is valid"
else:
  print "Signature is invalid"
```

## Alternative hashing

If you need to use other hash algorithms (e.g. SHA-1):

```
signature := private-key.sign message --hash=rsa.RsaKey.SHA-1
```
*/

/**
A pair of RSA keys generated together.

The $private-key and $public-key are mathematically linked and generated
  in a single operation.
*/
class RsaKeyPair:
  private-key/RsaKey
  public-key/RsaKey

  constructor .private-key .public-key:

  /** See $RsaKey.sign. */
  sign message/io.Data --hash/int=RsaKey.SHA-256 -> ByteArray:
    return private-key.sign message --hash=hash

  /** See $RsaKey.verify. */
  verify message/io.Data signature/ByteArray --hash/int=RsaKey.SHA-256 -> bool:
    return public-key.verify message signature --hash=hash

  /** See $RsaKey.encrypt. */
  encrypt data/ByteArray --padding/int=RsaKey.PADDING-PKCS1-V15 --hash/int=RsaKey.SHA-256 -> ByteArray:
    return public-key.encrypt data --padding=padding --hash=hash

  /** See $RsaKey.decrypt. */
  decrypt data/ByteArray --padding/int=RsaKey.PADDING-PKCS1-V15 --hash/int=RsaKey.SHA-256 -> ByteArray:
    return private-key.decrypt data --padding=padding --hash=hash

class RsaKey:
  /** Produces a 20-byte digest. */
  static SHA-1 ::= 1
  /** Default. Produces a 32-byte digest. */
  static SHA-256 ::= 256
  /** Produces a 48-byte digest. */
  static SHA-384 ::= 384
  /** Produces a 64-byte digest. */
  static SHA-512 ::= 512

  /** Padding scheme PKCS#1 v1.5. */
  static PADDING-PKCS1-V15 ::= 0
  /** Padding scheme PKCS#1 v2.1 (OAEP). */
  static PADDING-OAEP-V21  ::= 1

  /**
  The DER-encoded key bytes.

  For a private key this is a PKCS#1 RSAPrivateKey (or PKCS#8 PrivateKeyInfo)
  DER blob. For a public key this is a SubjectPublicKeyInfo DER blob.
  */
  der/ByteArray
  is-private/bool

  /** The size of the key DER in bytes. */
  size -> int: return der.size

  constructor.internal_ .der .is-private:

  /**
  Parses a PKCS#1 or PKCS#8 encoded private key and stores it as DER.
  The $key must be DER or PEM.
  The $password is optional and used for encrypted keys.
  */
  static parse-private key/io.Data --password/string?="" -> RsaKey:
    der := rsa-get-private-key-der_ key (password or "")
    return RsaKey.internal_ der true

  /**
  Parses a PKCS#1 or X.509 encoded public key and stores it as DER.
  The $key must be DER or PEM.
  */
  static parse-public key/io.Data -> RsaKey:
    der := rsa-get-public-key-der_ key
    return RsaKey.internal_ der false

  /**
  Generates a new RSA key pair.
  The $bits must be one of 1024, 2048, 3072, or 4096.
  The default is 2048.

  Returns an $RsaKeyPair with the $RsaKeyPair.private-key and $RsaKeyPair.public-key.
  */
  static generate --bits/int=2048 -> RsaKeyPair:
    if bits != 1024 and bits != 2048 and bits != 3072 and bits != 4096: throw "INVALID_ARGUMENT"
    pair := rsa-generate_ bits
    return RsaKeyPair
        RsaKey.internal_ pair[0] true
        RsaKey.internal_ pair[1] false

  /**
  Signs the $message with this private key.

  Hashes the $message using the specified $hash algorithm, and then signs
    the digest.

  The $hash must be one of $SHA-1, $SHA-256, $SHA-384, or $SHA-512.
  The default is $SHA-256.

  # Examples
  ```
  signature := key.sign "my message"
  ```
  */
  sign message/io.Data --hash/int=SHA-256 -> ByteArray:
    digest := compute-digest_ message hash
    return sign-digest digest --hash=hash

  /**
  Signs the $digest with this private key.

  The $digest must be the hash of the message to sign.
  The $hash is used to verify that the $digest has the correct length.
  */
  sign-digest digest/ByteArray --hash/int -> ByteArray:
    check-digest-length_ digest hash
    return rsa-sign_ der digest hash

  /**
  Verifies the $signature of the $message with this public key.

  Hashes the $message using the specified $hash algorithm, and then verifies
    the signature against the digest.

  The $hash must be one of $SHA-1, $SHA-256, $SHA-384, or $SHA-512.
  The default is $SHA-256.

  Returns true if the signature is valid, false otherwise.

  # Examples
  ```
  is-valid := key.verify "my message" signature
  ```
  */
  verify message/io.Data signature/ByteArray --hash/int=SHA-256 -> bool:
    digest := compute-digest_ message hash
    return verify-digest digest signature --hash=hash

  /**
  Verifies the $signature of the $digest with this public key.

  The $digest must be the hash of the message that was signed.
  The $hash is used to verify that the $digest has the correct length.
  Returns true if the signature is valid, false otherwise.
  */
  verify-digest digest/ByteArray signature/ByteArray --hash/int -> bool:
    check-digest-length_ digest hash
    return rsa-verify_ der digest signature hash

  /**
  Encrypts the given $data using the public key.
  The $padding must be either $PADDING-PKCS1-V15 or $PADDING-OAEP-V21.
  Default is $PADDING-PKCS1-V15.
  The $hash is used for OAEP padding and defaults to $SHA-256.
  */
  encrypt data/ByteArray --padding/int=PADDING-PKCS1-V15 --hash/int=SHA-256 -> ByteArray:
    return rsa-encrypt_ der data padding hash

  /**
  Decrypts the given $data using the private key.
  The $padding must be either $PADDING-PKCS1-V15 or $PADDING-OAEP-V21.
  Default is $PADDING-PKCS1-V15.
  The $hash is used for OAEP padding and defaults to $SHA-256.
  */
  decrypt data/ByteArray --padding/int=PADDING-PKCS1-V15 --hash/int=SHA-256 -> ByteArray:
    return rsa-decrypt_ der data padding hash

  /**
  Exports this key in PEM format.

  The format depends on whether this is a private or public key:
  - Private key → "-----BEGIN RSA PRIVATE KEY-----"
  - Public key  → "-----BEGIN PUBLIC KEY-----"
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
    header := is-private ? "-----BEGIN RSA PRIVATE KEY-----" : "-----BEGIN PUBLIC KEY-----"
    footer := is-private ? "-----END RSA PRIVATE KEY-----" : "-----END PUBLIC KEY-----"

    b64 := base64.encode der
    lines := [header]
    i := 0
    while i < b64.size:
      lines.add b64[i .. min (i + 64) b64.size]
      i += 64
    lines.add footer

    return lines.join "\n"

// Primitive: generates a new RSA key pair and returns [prv_der, pub_der].
rsa-generate_ bits/int -> List:
  #primitive.crypto.rsa-generate

// Primitive: sign a digest with a private key DER blob.
rsa-sign_ private-key-der/ByteArray digest/io.Data hash/int -> ByteArray:
  #primitive.crypto.rsa-sign

// Primitive: verify a signature against a digest using a public key DER blob.
rsa-verify_ public-key-der/ByteArray digest/ByteArray signature/ByteArray hash/int -> bool:
  #primitive.crypto.rsa-verify

// Primitive: parse any private key (PEM or DER) and return the canonical DER.
rsa-get-private-key-der_ key/io.Data password/string -> ByteArray:
  #primitive.crypto.rsa-get-private-key-der:
    return io.primitive-redo-io-data_ it key: | bytes |
      rsa-get-private-key-der_ bytes password

// Primitive: parse any public key (PEM or DER, or a private key) and return
// the canonical public-key DER.
rsa-get-public-key-der_ key/io.Data -> ByteArray:
  #primitive.crypto.rsa-get-public-key-der:
    return io.primitive-redo-io-data_ it key: | bytes |
      rsa-get-public-key-der_ bytes

// Primitive: encrypt data with a public key DER blob.
rsa-encrypt_ public-key-der/ByteArray data/ByteArray padding/int hash/int -> ByteArray:
  #primitive.crypto.rsa-encrypt

// Primitive: decrypt data with a private key DER blob.
rsa-decrypt_ private-key-der/ByteArray data/ByteArray padding/int hash/int -> ByteArray:
  #primitive.crypto.rsa-decrypt
  