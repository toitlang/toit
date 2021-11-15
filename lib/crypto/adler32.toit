// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

/**
Support for the Adler-32 checksum algorithm
  (https://en.wikipedia.org/wiki/Adler-32).

Adler-32 is a rolling checksum, so it is both possible to add to ($Adler32.add) and remove
  from (Adler32.unadd) the collection of checksummed data.

This implementation uses native primitives.
*/

/**
Computes the Adler32 checksum of the given $data.

The $data must be a string or byte array.
*/
adler32 data from/int=0 to/int=data.size -> ByteArray:
  return checksum Adler32 data from to

/** Checksummer that implements Adler-32. */
class Adler32 extends Checksum:
  adler_ := ?

  /**
  Constructs an Adler-32 checksummer.
  */
  constructor:
    adler_ = adler32_start_ resource_freeing_module_
    add_finalizer this:: finalize_checksum_ this

  /** See $super. */
  add data from/int to/int -> none:
    adler32_add_ adler_ data from to false

  /**
  Removes the $data from the start of the checksummed data.

  The $data must match bytes that were previously added to the checksummed
    data. This is for use of Adler32 as a rolling checksum.

  The $data must be a string or a byte array.
  */
  unadd data from/int=0 to/int=data.size -> none:
    adler32_add_ adler_ data from to true

  /**
  See $super.

  Destroys this object. Use $(get --destructive) with `--no-destructive`
    to keep the object.
  */
  // Needed to avoid missing implementation error.
  get -> ByteArray:
    return get --destructive=true

  /**
  Returns the current checksum.

  If $destructive, then destroys the Adler32 object.
  If not $destructive, allows to reuse the object.  This is mostly used for
    rolling checksums.
  */
  get --destructive -> ByteArray:
    if destructive:
      remove_finalizer this
    return adler32_get_ adler_ destructive

adler32_start_ group:
  #primitive.zlib.adler32_start

adler32_add_ adler collection from/int to/int unadd/bool:
  #primitive.zlib.adler32_add

adler32_get_ adler destructive:
  #primitive.zlib.adler32_get
