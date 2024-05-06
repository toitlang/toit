// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.sha show Sha224 Sha256 Sha384 Sha512
import crypto.checksum show Checksum checksum

import ..io as io

/**
HMAC keyed hashing for message authentication.
*/
class Hmac extends Checksum:
  hasher_ /Checksum
  final-hasher_ /Checksum

  /**
  Construct an Hmac checksum object.
  The $key must be a string or byte array.
  The $block-size must be the block size of the underlying hash.
  The $hasher-creator is a lambda that should create a new $Checksum object.
  */
  constructor --block-size/int key hasher-creator/Lambda:
    if key.size > block-size:
      key = checksum hasher-creator.call key
    if key is string:
      s := key as string
      key = ByteArray block-size
      key.replace 0 s
    else:
      key += ByteArray block-size - key.size  // Zero pad and copy.
    key.size.repeat: key[it] ^= 0x36  // Xor with ipad.
    hasher_ = hasher-creator.call
    hasher_.add key  // Start with the key xor ipad.
    key.size.repeat: key[it] ^= 0x6a  // == 0x36 ^ 0x5c  // Xor with opad instead.
    final-hasher_ = hasher-creator.call
    final-hasher_.add key  // Start with the key xor opad.

  constructor.private_ .final-hasher_ .hasher_:

  add data/io.Data from/int to/int -> none:
    hasher_.add data from to

  get -> ByteArray:
    step-4 := hasher_.get
    final-hasher_.add step-4
    return final-hasher_.get

  /**
  Creates a clone of the HMAC with the same key and the same prefix input.
  Call this immediately after creating the HMAC to save the key setup work and
    obtain an object that is efficient for small inputs.
  */
  clone -> Hmac:
    return Hmac.private_ final-hasher_.clone hasher_.clone

/**
HMAC using Sha-224 as the underlying hash.
*/
class HmacSha224 extends Hmac:
  /**
  Construct an Hmac SHA224 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block-size=Sha224.BLOCK-SIZE key:: Sha224

/**
HMAC using Sha-256 as the underlying hash.
*/
class HmacSha256 extends Hmac:
  /**
  Construct an Hmac SHA256 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block-size=Sha256.BLOCK-SIZE key:: Sha256

/**
HMAC using Sha-384 as the underlying hash.
*/
class HmacSha384 extends Hmac:
  /**
  Construct an Hmac SHA384 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block-size=Sha384.BLOCK-SIZE key:: Sha384

/**
HMAC using Sha-512 as the underlying hash.
*/
class HmacSha512 extends Hmac:
  /**
  Construct an Hmac SHA512 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block-size=Sha512.BLOCK-SIZE key:: Sha512

/**
Computes the HMAC using Sha-224 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac-sha224 --key data -> ByteArray:
  hmac := HmacSha224 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-256 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac-sha256 --key data -> ByteArray:
  hmac := HmacSha256 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-384 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac-sha384 --key data -> ByteArray:
  hmac := HmacSha384 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-512 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac-sha512 --key data -> ByteArray:
  hmac := HmacSha512 key
  hmac.add data
  return hmac.get
