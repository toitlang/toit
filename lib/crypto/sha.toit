// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .sha

/**
Secure Hash Algorithm (SHA-224, SHA-256, SHA-384, and SHA-512).

This implementation uses hardware accelerated primitives.

See https://en.wikipedia.org/wiki/SHA-256.
*/

/**
Computes the SHA224 hash of the given $data.

The $data must be a string or byte array.
*/
sha224 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha224 data from to

/**
Computes the SHA256 hash of the given $data.

The $data must be a string or byte array.
*/
sha256 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha256 data from to

/**
Computes the SHA384 hash of the given $data.

The $data must be a string or byte array.
*/
sha384 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha384 data from to

/**
Computes the SHA512 hash of the given $data.

The $data must be a string or byte array.
*/
sha512 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha512 data from to

/** SHA-224+ hash state. */
class Sha_ extends Checksum:
  sha_state_ := ?

  /** Constructs an empty SHA-224+ state */
  constructor bits/int:
    sha_state_ = sha_start_ resource_freeing_module_ bits
    add_finalizer this:: finalize_checksum_ this

  /** See $super. */
  add data from/int to/int -> none:
    sha_add_ sha_state_ data from to

  /**
  See $super.

  Calculates the SHA224+ hash.
  */
  get -> ByteArray:
    remove_finalizer this
    return sha_get_ sha_state_

/** SHA-224 hash state. */
class Sha224 extends Sha_:
  constructor:
    super 224

/** SHA-256 hash state. */
class Sha256 extends Sha_:
  constructor:
    super 256

/** SHA-384 hash state. */
class Sha384 extends Sha_:
  constructor:
    super 384

/** SHA-512 hash state. */
class Sha512 extends Sha_:
  constructor:
    super 512

// Gets a new empty Sha224+ object.
sha_start_ group bits/int:
  #primitive.crypto.sha_start

// Adds a UTF-8 string or a byte array to the sha224+ hash.
sha_add_ sha data from/int to/int -> none:
  #primitive.crypto.sha_add

// Rounds off a sha224+ hash and returns the hash.
sha_get_ sha -> ByteArray:
  #primitive.crypto.sha_get
