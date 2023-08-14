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

import binary show LITTLE-ENDIAN
import crypto.md5

class PartitionTable:
  static MAGIC-BYTES-MD5 ::= #[0xeb, 0xeb]
  partitions_/List ::= []

  add partition/Partition -> none:
    partitions_.add partition

  find --name/string -> Partition?:
    partitions_.do: | partition/Partition |
      if partition.name == name: return partition
    return null

  find-app -> Partition?:
    first/Partition? := null
    partitions_.do: | partition/Partition |
      if partition.type != Partition.TYPE-APP: continue.do
      if not first or partition.subtype < first.subtype:
        first = partition
    return first

  find-otadata -> Partition?:
    return find --type=Partition.TYPE-DATA --subtype=Partition.SUBTYPE-DATA-OTA

  find --type/int --subtype/int=0xff -> Partition?:
    partitions_.do: | partition/Partition |
      if partition.type != type: continue.do
      if subtype == 0xff or partition.subtype == subtype:
        return partition
    return null

  find-first-free-offset -> int:
    offset := 0
    partitions_.do: | partition/Partition |
      end := round-up (partition.offset + partition.size) 4096
      offset = max offset end
    return offset

  static decode bytes/ByteArray -> PartitionTable:
    table := PartitionTable
    checksum := md5.Md5
    cursor := 0
    while cursor < bytes.size:
      next := cursor + 32
      entry := bytes[cursor..next]
      if entry[..2] == MAGIC-BYTES-MD5:
        if entry[16..] != checksum.get:
          throw "Malformed table - wrong checksum"
      else if (entry.every: it == 0xff):
        return table
      else:
        table.add (Partition.decode entry)
        checksum.add entry
      cursor = next
    throw "Malformed table - not terminated"

  encode -> ByteArray:
    result := ByteArray 0x1000: 0xff
    sorted := partitions_.sort: | a b |
      a.offset.compare-to b.offset
    cursor := 0
    sorted.do: | partition/Partition |
      encoded := partition.encode
      result.replace cursor encoded
      cursor += encoded.size
    md5 := encode-md5-partition_ result[..cursor]
    result.replace cursor md5
    return result

  encode-md5-partition_ partitions/ByteArray -> ByteArray:
    checksum := md5.Md5
    checksum.add partitions
    partition := ByteArray 32: 0xff
    partition.replace 0 MAGIC-BYTES-MD5
    partition.replace 16 checksum.get
    return partition

  do [block]:
    partitions_.do block

class Partition:
  static MAGIC-BYTES ::= #[0xaa, 0x50]

  static TYPE-APP  ::= 0
  static TYPE-DATA ::= 1

  static SUBTYPE-DATA-OTA ::= 0

  // struct {
  //   uint8   magic[2];
  //   uint8   type;
  //   uint8   subtype;
  //   uint32  offset;
  //   uint32  size;
  //   uint8   name[16];
  //   uint32  flags;
  // }
  name/string
  type/int
  subtype/int
  offset/int
  size/int
  flags/int

  constructor --.name --.type --.subtype --.offset --.size --.flags:

  static decode bytes/ByteArray -> Partition:
    if bytes[..2] != MAGIC-BYTES: throw "Malformed entry - magic"
    return Partition
        --name=decode-name_ bytes[12..28]
        --type=bytes[2]
        --subtype=bytes[3]
        --offset=LITTLE-ENDIAN.uint32 bytes 4
        --size=LITTLE-ENDIAN.uint32 bytes 8
        --flags=LITTLE-ENDIAN.uint32 bytes 28

  encode -> ByteArray:
    result := ByteArray 32
    result.replace 0 MAGIC-BYTES
    result[2] = type
    result[3] = subtype
    LITTLE-ENDIAN.put-uint32 result 4 offset
    LITTLE-ENDIAN.put-uint32 result 8 size
    result.replace 12 encode-name_
    LITTLE-ENDIAN.put-uint32 result 28 flags
    return result

  static decode-name_ bytes/ByteArray -> string:
    zero := bytes.index-of 0
    if zero < 0: throw "Malformed entry - name"
    return bytes[..zero].to-string-non-throwing

  encode-name_ -> ByteArray:
    bytes := name.to-byte-array
    n := min 15 bytes.size
    return bytes[..n] + (ByteArray 16 - n)
