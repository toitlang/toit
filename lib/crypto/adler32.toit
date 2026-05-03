// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import ..io as io

/**
Support for the Adler-32 checksum algorithm
  (https://en.wikipedia.org/wiki/Adler-32).

Adler-32 is a rolling checksum, so it is both possible to add to ($Adler32.add) and remove
  from (Adler32.unadd) the collection of checksummed data.

This implementation uses native primitives.
*/

/**
Computes the Adler32 checksum of the given $data.
*/
adler32 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Adler32 data from to

/** Checksummer that implements Adler-32. */
class Adler32 extends Checksum:
  adler_ := ?

  /**
  Constructs an Adler-32 checksummer.
  */
  constructor:
    adler_ = adler32-start_ resource-freeing-module_
    add-finalizer this:: finalize-checksum_ this

  constructor.private_ .adler_:
    add-finalizer this:: finalize-checksum_ this

  /** See $super. */
  add data/io.Data from/int to/int -> none:
    adler32-add_ adler_ data from to false

  /**
  Removes the $data from the start of the checksummed data.

  The $data must match bytes that were previously added to the checksummed
    data. This is for use of Adler32 as a rolling checksum.

  The $data must be a string or a byte array.
  */
  unadd data/io.Data from/int=0 to/int=data.byte-size -> none:
    adler32-add_ adler_ data from to true

  /**
  See $super.

  Destroys this object. Use $(get --destructive) with `--no-destructive`
    to keep the object.
  */
  // Needed to avoid missing implementation error.
  get -> ByteArray:
    return get --destructive

  /**
  Returns the current checksum.

  If $destructive, then destroys the Adler32 object.
  If not $destructive, allows to reuse the object.  This is mostly used for
    rolling checksums.
  */
  get --destructive -> ByteArray:
    if destructive:
      remove-finalizer this
    return adler32-get_ adler_ destructive

  clone -> Adler32:
    return Adler32.private_ (adler32-clone_ adler_)

adler32-start_ group:
  #primitive.zlib.adler32-start

adler32-clone_ adler:
  #primitive.zlib.adler32-clone

adler32-add_ adler data/io.Data from/int to/int unadd/bool -> none:
  #primitive.zlib.adler32-add:
    io.primitive-redo-chunked-io-data_ it data from to: | bytes |
      adler32-add_ adler bytes 0 bytes.size unadd

adler32-get_ adler destructive:
  #primitive.zlib.adler32-get
