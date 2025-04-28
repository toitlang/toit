// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import ..io as io

/**
Blake2 Cryptographic Hash Function.

See https://datatracker.ietf.org/doc/html/rfc7693
*/

/**
Calculates the Blake2s hash of the given $data.
*/
blake2s data/io.Data from/int=0 to/int=data.byte-size --hash-size/int=32 --key/ByteArray=#[] -> ByteArray:
  return checksum (Blake2s --key=key --hash-size=hash-size) data from to

/** Blake2s-1 hash state. */
class Blake2s extends Checksum:
  blake2s-state_ := ?
  hash-size_/int

  /** Constructs an empty Blake2s state. */
  constructor --hash-size/int=32 --key/ByteArray=#[]:
    hash-size_ = hash-size
    blake2s-state_ = blake2s-start_ resource-freeing-module_ key hash-size
    add-finalizer this:: finalize-checksum_ this

  constructor.private_ .blake2s-state_ hash-size/int:
    hash-size_ = hash-size
    add-finalizer this:: finalize-checksum_ this

  /** See $super. */
  add data/io.Data from/int to/int -> none:
    blake2s-add_ blake2s-state_ data from to

  /**
  See $super.

  Calculates the Blake2s hash.
  */
  get -> ByteArray:
    remove-finalizer this
    return blake2s-get_ blake2s-state_ hash-size_

  clone -> Blake2s:
    return Blake2s.private_ (blake2s-clone_ blake2s-state_) hash-size_

// Gets a new empty Blake2s object.
blake2s-start_ group key/ByteArray hash-size/int:
  #primitive.crypto.blake2s-start

// Clones a Blake2s object.
blake2s-clone_ blake2s:
  #primitive.crypto.blake2s-clone

// Adds a UTF-8 string or a byte array to the blake2s hash.
blake2s-add_ blake2s data/io.Data from/int to/int -> none:
  #primitive.crypto.blake2s-add:
    io.primitive-redo-chunked-io-data_ it data from to: | bytes |
      blake2s-add_ blake2s bytes 0 bytes.size

// Rounds off a blake2s hash.
blake2s-get_ blake2s hash-size/int -> ByteArray:
  #primitive.crypto.blake2s-get

