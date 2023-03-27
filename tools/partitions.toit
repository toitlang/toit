// Copyright (C) 2023 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import binary show LITTLE_ENDIAN
import crypto
import crypto.sha256

import expect show *

class PartitionTable:
  partitions_/List ::= []

  add partition/Partition -> none:
    partitions_.add partition

  encode -> ByteArray:
    result := ByteArray 0x1000: 0xff
    sorted := partitions_.sort: | a b | a.offset < b.offset
    cursor := 0
    sorted.do: | partition/Partition |
      encoded := partition.encode
      result.replace cursor encoded
      cursor += encoded.size
    // TODO(kasper): Add md5 entry
    return result

class Partition:
  static MAGIC_BYTES ::= #[0xaa, 0x50]

  name/string
  type/int
  subtype/int
  offset/int
  size/int
  flags/int

  constructor --.name --.type --.subtype --.offset --.size --.flags:

  // b'<2sBBLL16sL'
  encode -> ByteArray:
    result := ByteArray 32
    name_bytes := name.to_byte_array
    name_size:= min 15 name_bytes.size
    encoded_name := name_bytes[..name_size] + (ByteArray 16 - name_size)
    print "encoded-name = $encoded_name"
    result.replace 0 MAGIC_BYTES
    result[2] = type
    result[3] = subtype
    LITTLE_ENDIAN.put_uint32 result 4 offset
    LITTLE_ENDIAN.put_uint32 result 8 size
    result.replace 12 encoded_name
    LITTLE_ENDIAN.put_uint32 result 28 flags
    return result
