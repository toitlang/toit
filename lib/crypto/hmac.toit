// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.sha show Sha224 Sha256 Sha384 Sha512
import crypto.checksum show Checksum checksum

/**
HMAC keyed hashing for message authentication.
*/
class Hmac extends Checksum:
  hasher_creator /Lambda
  hasher_ /Checksum
  key /ByteArray
  block_size_ /int

  /**
  Construct an Hmac Checksum object.
  The $key must be a string or byte array.
  The $block_size must be the block size of the underlying hash.
  The $hasher_creator is a lambda that should create a new $Checksum object.
  */
  constructor --block_size/int key .hasher_creator/Lambda:
    block_size_ = block_size
    if key.size > block_size:
      key = checksum hasher_creator.call key
    if key is string:
      s := key as string
      key = ByteArray block_size
      key.replace 0 s
    else:
      key += ByteArray block_size - key.size  // Zero pad and copy.
    this.key = key
    key.size.repeat: key[it] ^= 0x36  // Xor with ipad.
    hasher_ = hasher_creator.call
    hasher_.add key  // Start with the key xor ipad.
    key.size.repeat: key[it] ^= 0x36 ^ 0x5c  // Xor with opad instead.

  add data from/int to/int -> none:
    hasher_.add data from to

  get -> ByteArray:
    step_4 := hasher_.get
    hasher := hasher_creator.call
    hasher.add key
    hasher.add step_4
    return hasher.get

/**
HMAC using Sha-224 as the underlying hash.
*/
class HmacSha224 extends Hmac:
  /**
  Construct an Hmac SHA224 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key/ByteArray:
    super --block_size=64 key:: Sha224

/**
HMAC using Sha-256 as the underlying hash.
*/
class HmacSha256 extends Hmac:
  /**
  Construct an Hmac SHA256 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key/ByteArray:
    super --block_size=64 key:: Sha256

/**
HMAC using Sha-384 as the underlying hash.
*/
class HmacSha384 extends Hmac:
  /**
  Construct an Hmac SHA384 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key/ByteArray:
    super --block_size=128 key:: Sha384

/**
HMAC using Sha-512 as the underlying hash.
*/
class HmacSha512 extends Hmac:
  /**
  Construct an Hmac SHA512 Checksum object.
  The $key must be a string or byte array.
  */
  constructor key/ByteArray:
    super --block_size=128 key:: Sha512

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
