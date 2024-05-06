// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

/**
Checksum framework.

The $Checksum abstract class defines the structure of checksumming
  algorithms.
*/

/**
Base for checksum algorithms.

The add methods ($(add data), $(add data from), and
  ($add data from to)) add data to be checksummed.
To get the checksum use $get.
*/
abstract class Checksum:

  /** Variant of $(add data from to). */
  add data/io.Data -> none:
    add data 0 data.byte-size

  /** Variant of $(add data from to). */
  add data/io.Data from/int -> none:
    add data from data.byte-size

  /**
  Adds the $data to the data to be checksummed.
  */
  abstract add data/io.Data from/int to/int -> none

  /** Computes the checksum from the added data. */
  abstract get -> ByteArray

  /**
  Clones the internal state so we can compute checksums of multiple data with
    the same prefix.
  */
  abstract clone -> Checksum

/**
Computes the hash of the given $data.

The $data must be a string or a byte array.
*/
checksum summer/Checksum data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  summer.add data from to
  return summer.get

finalize-checksum_ checksum/Checksum -> none:
  checksum.get
