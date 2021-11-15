// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

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
  add data -> none:
    if data is not string and data is not ByteArray:
      throw "WRONG_OBJECT_TYPE"
    add data 0 data.size

  /** Variant of $(add data from to). */
  add data from/int -> none:
    if data is not string and data is not ByteArray:
      throw "WRONG_OBJECT_TYPE"
    add data from data.size

  /**
  Adds the $data to the data to be checksummed.

  The $data must be a string of a byte array.
  */
  abstract add data from/int to/int -> none

  /** Computes the checksum from the added data. */
  abstract get -> ByteArray

/**
Computes the hash of the given $data.

The $data must be a string or a byte array.
*/
checksum summer/Checksum data from/int=0 to/int=data.size -> ByteArray:
  summer.add data from to
  return summer.get

finalize_checksum_ checksum/Checksum -> none:
  checksum.get
