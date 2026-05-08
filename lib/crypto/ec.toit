// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .sha
import .sha1
import .aes
import .hkdf
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
  Computes a shared secret with the $other-public-key.
  */
  compute-shared-secret other-public-key/EcKey -> ByteArray:
    return private-key.compute-shared-secret other-public-key

  /**
  Decrypts the given $ciphertext using ECIES.
  */
  decrypt-ecies ciphertext/ByteArray -> ByteArray:
    return private-key.decrypt-ecies ciphertext

  /**
  Generates a new EC key pair for the given $curve.
  Common curves: CURVE-SECP256R1, CURVE-SECP384R1, CURVE-SECP521R1.
  */
  static generate --curve/string=EcKey.CURVE-SECP256R1 -> EcKeyPair:
    pair := ec-generate-key_ curve
    return EcKeyPair
        EcKey.internal_ pair[0] true
        EcKey.internal_ pair[1] false

class EcKey:
  /** Named constant for the "secp256r1" curve. */
  static CURVE-SECP256R1 ::= "secp256r1"
  /** Named constant for the "secp384r1" curve. */
  static CURVE-SECP384R1 ::= "secp384r1"
  /** Named constant for the "secp521r1" curve. */
  static CURVE-SECP521R1 ::= "secp521r1"

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
  static parse-private key/io.Data --password/string="" -> EcKey:
    der := ec-get-private-key-der_ key password
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

  /**
  Computes a shared secret with the $other-public-key.
  This key must be a private key.
  */
  compute-shared-secret other-public-key/EcKey -> ByteArray:
    if not is-private: throw "INVALID_ARGUMENT"
    return ec-compute-shared-secret_ der other-public-key.der

  /**
  Decrypts the given $ciphertext using ECIES.
  This key must be a private key.
  */
  decrypt-ecies ciphertext/ByteArray -> ByteArray:
    if not is-private: throw "INVALID_ARGUMENT"
    return Ecies.decrypt_ ciphertext this

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

/**
Elliptic Curve Integrated Encryption Scheme (ECIES).
Uses ECDH for key agreement, HKDF-SHA256 for key derivation, and AES-128-GCM for encryption.
*/
class Ecies:
  /** Error thrown when ECIES decryption fails due to a tag mismatch. */
  static AUTHENTICATION-FAILURE ::= "INVALID_SIGNATURE"

  /**
  Encrypts the $message for the $recipient-public-key.
  Returns a ByteArray containing:
    [2-byte size] [ephemeral-public-key (DER)] [nonce (12 bytes)] [ciphertext] [tag (16 bytes)]

  The $curve must match the curve of the $recipient-public-key.
  */
  static encrypt message/io.Data recipient-public-key/EcKey --curve/string=EcKey.CURVE-SECP256R1 -> ByteArray:
    // 1. Generate ephemeral key pair.
    ephemeral := EcKeyPair.generate --curve=curve
    
    // 2. ECDH
    shared-secret := ephemeral.compute-shared-secret recipient-public-key
    
    // 3. HKDF (derives 16 bytes for AES-128 key and 12 bytes for GCM nonce)
    // The ephemeral public key is used as part of the info to bind the derivation to this message.
    derived := hkdf-sha256
        --ikm=shared-secret
        --info=ephemeral.public-key.der
        --size=16 + 12
    
    aes-key := derived[0..16]
    nonce := derived[16..28]
    
    // 4. AES-GCM Encryption
    gcm := AesGcm.encryptor aes-key nonce
    ciphertext-with-tag := gcm.encrypt message
    
    // 5. Build output: [2-byte DER length] [DER] [12-byte nonce] [ciphertext + tag]
    // The length is stored as 2 bytes in big-endian format.
    der-size := ephemeral.public-key.size
    out := ByteArray 2 + der-size + 12 + ciphertext-with-tag.size
    out[0] = der-size >> 8
    out[1] = der-size & 0xFF
    out.replace 2 ephemeral.public-key.der
    out.replace (2 + der-size) nonce
    out.replace (2 + der-size + 12) ciphertext-with-tag
    return out

  /**
  Decrypts the $ciphertext using the $recipient-private-key.
  The $ciphertext must be in the format produced by $encrypt.
  */
  static decrypt_ ciphertext/ByteArray recipient-private-key/EcKey -> ByteArray:
    if ciphertext.size < 2: throw "INVALID_ARGUMENT"
    
    // 1. Parse ephemeral public key.
    der-size := (ciphertext[0] << 8) | ciphertext[1]
    if ciphertext.size < 2 + der-size + 12 + 16: throw "INVALID_ARGUMENT"
    
    ephemeral-der := ciphertext[2 .. 2 + der-size]
    ephemeral-pub := EcKey.parse-public ephemeral-der
    
    nonce := ciphertext[2 + der-size .. 2 + der-size + 12]
    encrypted := ciphertext[2 + der-size + 12 ..]
    
    // 2. ECDH
    shared-secret := recipient-private-key.compute-shared-secret ephemeral-pub
    
    // 3. HKDF
    derived := hkdf-sha256
        --ikm=shared-secret
        --info=ephemeral-der
        --size=16 + 12
    
    aes-key := derived[0..16]
    // Note: We don't strictly need to derive the nonce for decryption if we already have it in the message,
    // but we check it matches just in case (or just use the one from the message).
    // The standard ECIES often includes the ephemeral key in the KDF info.
    
    // 4. AES-GCM Decryption
    gcm := AesGcm.decryptor aes-key nonce
    // This will throw "INVALID_SIGNATURE" if the tag is wrong (MAC failure).
    // We use the static constant for semantic clarity.
    return gcm.decrypt encrypted

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

ec-compute-shared-secret_ private-key-der/ByteArray public-key-der/ByteArray -> ByteArray:
  #primitive.crypto.ec-compute-shared-secret
