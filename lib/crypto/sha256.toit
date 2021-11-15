// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

/**
Secure Hash Algorithm 256 (SHA-256).

This implementation uses hardware accelerated primitives.

See https://en.wikipedia.org/wiki/SHA-256.
*/

/**
Computes the SHA256 hash of the given $data.

The $data must be a string or byte array.
*/
sha256 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha256 data from to

/** SHA-256 hash state. */
class Sha256 extends Checksum:
  sha256_state_ := ?

  /** Constructs an empty SHA-256 state */
  constructor:
    sha256_state_ = sha256_start_ resource_freeing_module_
    add_finalizer this:: finalize_checksum_ this

  /** See $super. */
  add data from/int to/int -> none:
    sha256_add_ sha256_state_ data from to

  /**
  See $super.

  Calculates the SHA256 hash.
  */
  get -> ByteArray:
    remove_finalizer this
    return sha256_get_ sha256_state_

// Gets a new empty Sha256 object.
sha256_start_ group:
  #primitive.crypto.sha256_start

// Adds a UTF-8 string or a byte array to the sha256 hash.
sha256_add_ sha256 data from/int to/int -> none:
  #primitive.crypto.sha256_add

// Rounds off a sha256 hash and return the hash.
sha256_get_ sha256 -> ByteArray:
  #primitive.crypto.sha256_get
