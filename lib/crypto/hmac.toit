// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.sha show Sha224 Sha256 Sha384 Sha512
import crypto.checksum show Checksum checksum

/**
HMAC keyed hashing for message authentication.
*/
class Hmac extends Checksum:
  hasher_ /Checksum
  final_hasher_ /Checksum

  /**
  Construct an Hmac checksum object.
  The $key must be a string or byte array.
  The $block_size must be the block size of the underlying hash.
  The $hasher_creator is a lambda that should create a new $Checksum object.
  */
  constructor --block_size/int key hasher_creator/Lambda:
    if key.size > block_size:
      key = checksum hasher_creator.call key
    if key is string:
      s := key as string
      key = ByteArray block_size
      key.replace 0 s
    else:
      key += ByteArray block_size - key.size  // Zero pad and copy.
    key.size.repeat: key[it] ^= 0x36  // Xor with ipad.
    hasher_ = hasher_creator.call
    hasher_.add key  // Start with the key xor ipad.
    key.size.repeat: key[it] ^= 0x6a  // == 0x36 ^ 0x5c  // Xor with opad instead.
    final_hasher_ = hasher_creator.call
    final_hasher_.add key  // Start with the key xor opad.

  constructor.private_ .final_hasher_ .hasher_:

  add data from/int to/int -> none:
    hasher_.add data from to

  get -> ByteArray:
    step_4 := hasher_.get
    final_hasher_.add step_4
    return final_hasher_.get

  /**
  Creates a clone of the HMAC with the same key and the same prefix input.
  Call this immediately after creating the HMAC to save the key setup work and
    obtain an object that is efficient for small inputs.
  */
  clone -> Hmac:
    return Hmac.private_ final_hasher_.clone hasher_.clone

/**
HMAC using Sha-224 as the underlying hash.
*/
class HmacSha224 extends Hmac:
  /**
  Construct an Hmac SHA224 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block_size=Sha224.BLOCK_SIZE key:: Sha224

/**
HMAC using Sha-256 as the underlying hash.
*/
class HmacSha256 extends Hmac:
  /**
  Construct an Hmac SHA256 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block_size=Sha256.BLOCK_SIZE key:: Sha256

/**
HMAC using Sha-384 as the underlying hash.
*/
class HmacSha384 extends Hmac:
  /**
  Construct an Hmac SHA384 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block_size=Sha384.BLOCK_SIZE key:: Sha384

/**
HMAC using Sha-512 as the underlying hash.
*/
class HmacSha512 extends Hmac:
  /**
  Construct an Hmac SHA512 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key:
    super --block_size=Sha512.BLOCK_SIZE key:: Sha512

/**
Computes the HMAC using Sha-224 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac_sha224 --key data -> ByteArray:
  hmac := HmacSha224 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-256 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac_sha256 --key data -> ByteArray:
  hmac := HmacSha256 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-384 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac_sha384 --key data -> ByteArray:
  hmac := HmacSha384 key
  hmac.add data
  return hmac.get

/**
Computes the HMAC using Sha-512 of the given $data.
The $data must be a string or byte array.
The $key (secret) must be a string or byte array.
*/
hmac_sha512 --key data -> ByteArray:
  hmac := HmacSha512 key
  hmac.add data
  return hmac.get
