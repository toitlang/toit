// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import ..io as io

/**
Secure Hash Algorithm 1 (SHA-1).

This implementation uses hardware accelerated primitives.

See https://en.wikipedia.org/wiki/SHA-1.
*/

/**
Calculates the SHA-1 hash of the given $data.
*/
sha1 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Sha1 data from to

/** SHA-1 hash state. */
class Sha1 extends Checksum:
  sha1-state_ := ?

  /** Constructs an empty SHA-1 state. */
  constructor:
    sha1-state_ = sha1-start_ resource-freeing-module_
    add-finalizer this:: finalize-checksum_ this

  constructor.private_ .sha1-state_:
    add-finalizer this:: finalize-checksum_ this

  /** See $super. */
  add data/io.Data from/int to/int -> none:
    sha1-add_ sha1-state_ data from to

  /**
  See $super.

  Calculates the SHA1 hash.
  */
  get -> ByteArray:
    remove-finalizer this
    return sha1-get_ sha1-state_

  clone -> Sha1:
    return Sha1.private_ (sha1-clone_ sha1-state_)

// Gets a new empty Sha1 object.
sha1-start_ group:
  #primitive.crypto.sha1-start

// Clones a Sha1 object.
sha1-clone_ sha1:
  #primitive.crypto.sha1-clone

// Adds a UTF-8 string or a byte array to the sha1 hash.
sha1-add_ sha1 data/io.Data from/int to/int -> none:
  #primitive.crypto.sha1-add:
    io.primitive-redo-chunked-io-data_ it data from to: | bytes |
      sha1-add_ sha1 bytes 0 bytes.size

// Rounds off a sha1 hash.
sha1-get_ sha1 -> ByteArray:
  #primitive.crypto.sha1-get
