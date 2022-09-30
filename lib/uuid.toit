// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Support for universally unique identifiers (UUIDs).

This library contains the UUID class ($Uuid), and supports the
  creation of version 5 UUIDs ($uuid5).

See https://en.wikipedia.org/wiki/Universally_unique_identifier.
*/

import crypto.sha1 as crypto

/** Bytesize of a UUID. */
// TODO(4193): should the name of the constant be less ambiguous?
SIZE ::= 16

/**
The Nil UUID.
This UUID is composed of all bits set to zero.
*/
NIL ::= Uuid
  ByteArray SIZE

/**
Parses the given $str as a UUID.

Supports the canonical textual representation, consisting of 16 bytes encoded
  as 32 hexademical values. The hexadecimal values should be split into 5
  groups, separated by a dash ('-'). The groups should contain respectively
  8, 4, 4, 4, and 12 hexadecimal characters.

# Examples
```
parse "123e4567-e89b-12d3-a456-426614174000"
```
*/
parse str/string:
  uuid := ByteArray SIZE
  index := 0
  i := 0
  thrower := (: throw "INVALID_UUID")
  while i < str.size and index < uuid.size:
    if (str.at --raw i) == '-': i++
    v := hex_digit str[i++] thrower
    v <<= 4
    v |= hex_digit str[i++] thrower
    uuid[index++] = v
  if i < str.size or index != uuid.size: throw "INVALID_UUID"
  return Uuid uuid

/**
Builds a version 5 UUID from the given $namespace and $data.
Both $namespace and $data can be either strings or byte arrays.

The generated UUID uses the variant 1 (RFC 4122/DCE 1.1), and is
  thus also known as "Leach-Salz" UUID.
*/
// TODO(4197): should be typed.
uuid5 namespace data:
  hash := crypto.Sha1
  // TODO(4197): why do we need to call `to_byte_array` here.
  //   Is the documentation wrong and we want to accept more than
  //   just strings and byte arrays?
  hash.add namespace.to_byte_array
  hash.add data
  uuid := hash.get

  // Version 5
  uuid[6] = (uuid[6] & 0xf) | 0x50
  // Variant 1
  uuid[8] = (uuid[8] & 0x3f) | 0x80

  return Uuid
    uuid.copy 0 SIZE

/**
A universally unique identifier, UUID.

UUIDs are equivalent to a 128-bit number. Through the use of
  cryptographic hash functions (for version 5, SHA1) UUIDs
  are practically unique.

See https://en.wikipedia.org/wiki/Universally_unique_identifier.
*/
class Uuid:
  // TODO(4196): the field should be types as `ByteArray`.
  bytes_ ::= ?
  hash_ := null

  /**
  Creates a UUID from $bytes_.

  The given parameter must be a byte array of size 16.
  */
  constructor .bytes_:
    if bytes_.size != SIZE: throw "INVALID_UUID"

  /**
  Creates the NIL UUID.
  All bits of the UUID are zero.

  Deprecated. Use $NIL instead.
  */
  constructor.all_zeros:
    zeros := ByteArray SIZE
    return Uuid zeros

  /**
  Converts this instance to the canonical text representation of UUIDs.

  Converts the 128 bits of this instance into hexadecimal values, and groups
  them in 8, 4, 4, 4, and 12 character segments, each separated by a "-".

  For example, a result of this method could be:
    `"123e4567-e89b-12d3-a456-426614174000"`
  */
  stringify:
    buffer := ByteArray 36
    index := 0
    for i := 0; i < SIZE; i++:
      if index == 8 or index == 13 or index == 18 or index == 23:
        buffer[index++] = '-'
      c := bytes_[i]
      buffer[index++] = to_lower_case_hex c >> 4
      buffer[index++] = to_lower_case_hex c & 0xf
    return buffer.to_string

  /**
  Converts this instance into a byte array.
  The returned byte array is 16 bytes long and contains the 128 bits
    of this UUID.

  The returned byte array is a valid input for the UUID constructor.
  */
  to_byte_array -> ByteArray:
    return bytes_

  /** Whether this instance has the same 128 bits as $other. */
  operator == other -> bool:
    if other is not Uuid: return false
    other_bytes := other.bytes_
    for i := 0; i < SIZE; i++:
      if bytes_[i] != other_bytes[i]: return false
    return true

  /** A hash code for this instance. */
  // The "randomness" of the UUID bytes is uniformly distributed
  // across all the bytes, so we just use the first three bytes
  // and stay in the small integer range.
  hash_code -> int:
    hash := hash_
    if hash: return hash
    else: return hash_ = bytes_[0] | bytes_[1] << 8 | bytes_[2] << 16

  /** Whether this instance is equal to the nil UUID $NIL. */
  is_nil -> bool: return not bytes_.any: it != 0
