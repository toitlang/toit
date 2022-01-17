// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

/**
SipHash

See https://en.wikipedia.org/wiki/SipHash
*/

/**
Calculates the SipHash of the given $data.

The $data must be a string or a byte array.

The $key must be a 16 element byte array.

The $output_length must be 8 or 16 bytes.
*/
siphash data key/ByteArray --output_length/int=16 --c_rounds/int=2 --d_rounds/int=4 from/int=0 to/int=data.size -> ByteArray:
  return checksum (Siphash key --output_length=output_length --c_rounds=c_rounds --d_rounds=d_rounds) data from to

/** SipHash state. */
class Siphash extends Checksum:
  siphash_state_ := ?

  /** Constructs an empty SipHash state. */
  constructor key --output_length/int=16 --c_rounds/int=2 --d_rounds/int=4:
    siphash_state_ = siphash_start_ resource_freeing_module_ key output_length c_rounds d_rounds
    add_finalizer this:: finalize_checksum_ this

  /** See $super. */
  add data from/int to/int -> none:
    siphash_add_ siphash_state_ data from to

  /**
  See $super.

  Calculates the SipHash.
  */
  get -> ByteArray:
    remove_finalizer this
    return siphash_get_ siphash_state_

// Gets a new empty SipHash object.
siphash_start_ group key output_length c_rounds d_rounds -> none:
  #primitive.crypto.siphash_start

// Adds a UTF-8 string or a byte array to the Sip hash.
siphash_add_ siphash data from/int to/int -> none:
  #primitive.crypto.siphash_add

// Rounds off a Sip hash.
siphash_get_ siphash -> ByteArray:
  #primitive.crypto.siphash_get
