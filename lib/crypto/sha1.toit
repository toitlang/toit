// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

/**
Secure Hash Algorithm 1 (SHA-1).

This implementation uses hardware accelerated primitives.

See https://en.wikipedia.org/wiki/SHA-1.
*/

/**
Calculates the SHA-1 hash of the given $data.

The $data must be a string or a byte array.
*/
sha1 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Sha1 data from to

/** SHA-1 hash state. */
class Sha1 extends Checksum:
  sha1_state_ := ?

  /** Constructs an empty SHA-1 state. */
  constructor:
    sha1_state_ = sha1_start_ resource_freeing_module_
    add_finalizer this:: finalize_checksum_ this

  /** See $super. */
  add data from/int to/int -> none:
    sha1_add_ sha1_state_ data from to

  /**
  See $super.

  Calculates the SHA1 hash.
  */
  get -> ByteArray:
    remove_finalizer this
    return sha1_get_ sha1_state_

// Gets a new empty Sha1 object.
sha1_start_ group -> none:
  #primitive.crypto.sha1_start

// Adds a UTF-8 string or a byte array to the sha1 hash.
sha1_add_ sha1 data from/int to/int -> none:
  #primitive.crypto.sha1_add

// Rounds off a sha1 hash.
sha1_get_ sha1 -> ByteArray:
  #primitive.crypto.sha1_get
