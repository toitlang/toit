// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.sha show Sha256 Sha384
import crypto.checksum show Checksum

/**
HMAC keyed hashing for message authentication.
*/
class Hmac extends Checksum:
  hasher_creator /Lambda
  hasher_ /Checksum
  key /ByteArray
  block_size_ /int

  constructor --block_size/int=64 key .hasher_creator/Lambda:
    block_size_ = block_size
    if key.size > block_size:
      hasher/Checksum := hasher_creator.call
      hasher.add key
      key = hasher.get
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
HMAC using Sha-256 as the underlying hash.
*/
class HmacSha256 extends Hmac:
  constructor key/ByteArray:
    super --block_size=64 key:: Sha256

/**
HMAC using Sha-384 as the underlying hash.
*/
class HmacSha384 extends Hmac:
  constructor key/ByteArray:
    super --block_size=64 key:: Sha384
