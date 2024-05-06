// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import ..io as io

/**
SipHash

See https://en.wikipedia.org/wiki/SipHash
*/

/**
Calculates the SipHash of the given $data.

The $data must be a string or a byte array.

The $key must be a 16 element byte array.

The $output-length must be 8 or 16 bytes.
*/
siphash data/io.Data key/ByteArray --output-length/int=16 --c-rounds/int=2 --d-rounds/int=4 from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum (Siphash key --output-length=output-length --c-rounds=c-rounds --d-rounds=d-rounds) data from to

/** SipHash state. */
class Siphash extends Checksum:
  siphash-state_ := ?

  /** Constructs an empty SipHash state. */
  constructor key --output-length/int=16 --c-rounds/int=2 --d-rounds/int=4:
    siphash-state_ = siphash-start_ resource-freeing-module_ key output-length c-rounds d-rounds
    add-finalizer this:: finalize-checksum_ this

  constructor.private_ .siphash-state_:
    add-finalizer this:: finalize-checksum_ this

  /** See $super. */
  add data/io.Data from/int to/int -> none:
    siphash-add_ siphash-state_ data from to

  /**
  See $super.

  Calculates the SipHash.
  */
  get -> ByteArray:
    remove-finalizer this
    return siphash-get_ siphash-state_

  clone -> Siphash:
    return Siphash.private_ (siphash-clone_ siphash-state_)

// Gets a new empty SipHash object.
siphash-start_ group key output-length c-rounds d-rounds:
  #primitive.crypto.siphash-start

// Clones
siphash-clone_ other:
  #primitive.crypto.siphash-clone

// Adds a UTF-8 string or a byte array to the Sip hash.
siphash-add_ siphash data/io.Data from/int to/int -> none:
  #primitive.crypto.siphash-add:
    io.primitive-redo-chunked-io-data_ it data from to: | bytes |
      siphash-add_ siphash bytes 0 bytes.size

// Rounds off a Sip hash.
siphash-get_ siphash -> ByteArray:
  #primitive.crypto.siphash-get
