// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Support for universally unique identifiers (UUIDs).

This library contains the UUID class ($Uuid), and supports the
  creation of version 5 UUIDs ($uuid5).

See https://en.wikipedia.org/wiki/Universally_unique_identifier.
*/

import crypto
import crypto.sha1 as crypto
import io

/// Deprecated. Use $Uuid.SIZE instead.
SIZE ::= Uuid.SIZE

/// Deprecated. Use $Uuid.NIL instead.
NIL ::= Uuid.NIL

/// Deprecated. Use $Uuid.parse instead.
parse str/string [--on-error] -> Uuid?:
  return Uuid.parse str --on-error=on-error

/// Deprecated. Use $Uuid.parse instead.
parse str/string -> Uuid:
  return Uuid.parse str

/// Deprecated. Use $Uuid.uuid5 instead.
uuid5 namespace/io.Data data/io.Data -> Uuid:
  return Uuid.uuid5 namespace data

/**
A universally unique identifier, UUID.

UUIDs are equivalent to a 128-bit number. Through the use of
  cryptographic hash functions (for version 5, SHA1) UUIDs
  are practically unique.

See https://en.wikipedia.org/wiki/Universally_unique_identifier.
*/
class Uuid:

  /** Bytesize of a UUID. */
  // TODO(4193): should the name of the constant be less ambiguous?
  static SIZE ::= 16

  /**
  The Nil UUID.
  This UUID is composed of all bits set to zero.
  */
  static NIL ::= Uuid (ByteArray SIZE)

  /**
  Parses the given $str as a UUID.

  Supports the canonical textual representation, consisting of 16 bytes encoded
    as 32 hexademical values. The hexadecimal values should be split into 5
    groups, separated by a dash ('-'). The groups should contain respectively
    8, 4, 4, 4, and 12 hexadecimal characters.

  Calls $on-error (and returns its result) if $str is not a valid UUID.

  # Examples
  ```
  parse "123e4567-e89b-12d3-a456-426614174000"
  ```
  */
  static parse str/string [--on-error] -> Uuid?:
    uuid := ByteArray SIZE
    index := 0
    i := 0
    error-handler := (: return on-error.call)
    while i < str.size and index < uuid.size:
      if (str.at --raw i) == '-': i++
      if i + 1 >= str.size: return on-error.call
      v := hex-char-to-value str[i++] --on-error=error-handler
      v <<= 4
      v |= hex-char-to-value str[i++] --on-error=error-handler
      uuid[index++] = v
    if i < str.size or index != uuid.size:
      return on-error.call
    return Uuid uuid

  /**
  Variant of $(parse str [--on-error]) that throws an error if $str is not a
    valid UUID.
  */
  static parse str/string -> Uuid:
    return parse str --on-error=(: throw "INVALID_UUID")

  /**
  Builds a version 5 UUID from the given $namespace and $data.

  The generated UUID uses the variant 1 (RFC 4122/DCE 1.1), and is
    thus also known as "Leach-Salz" UUID.
  */
  static uuid5 namespace/io.Data data/io.Data -> Uuid:
    hash := crypto.Sha1
    hash.add namespace
    hash.add data
    uuid := hash.get

    // Version 5
    uuid[6] = (uuid[6] & 0xf) | 0x50
    // Variant 1
    uuid[8] = (uuid[8] & 0x3f) | 0x80

    return Uuid
      uuid.copy 0 SIZE

  /**
  Generates a random UUID.
  */
  static random -> Uuid:
    return Uuid
      crypto.random --size=SIZE

  /**
  Returns whether the given $str is a valid UUID.
  */
  static is-valid str/string -> bool:
    parse str --on-error=: return false
    return true

  bytes_/ByteArray
  hash_ := null

  /**
  Creates a UUID from $bytes_.

  The given parameter must be a byte array of size 16.
  */
  constructor .bytes_:
    if bytes_.size != SIZE: throw "INVALID_UUID"

  /**
  Converts this instance to a string.

  Use $to-string to get the canonical text representation of UUIDs.
  */
  stringify -> string:
    return to-string

  /**
  Converts this instance to the canonical text representation of UUIDs.

  Converts the 128 bits of this instance into hexadecimal values, and groups
  them in 8, 4, 4, 4, and 12 character segments, each separated by a "-".

  For example, a result of this method could be:
    `"123e4567-e89b-12d3-a456-426614174000"`
  */
  to-string -> string:
    buffer := ByteArray 36
    index := 0
    for i := 0; i < SIZE; i++:
      if index == 8 or index == 13 or index == 18 or index == 23:
        buffer[index++] = '-'
      c := bytes_[i]
      buffer[index++] = to-lower-case-hex c >> 4
      buffer[index++] = to-lower-case-hex c & 0xf
    return buffer.to-string

  /**
  Converts this instance into a byte array.
  The returned byte array is 16 bytes long and contains the 128 bits
    of this UUID.

  The returned byte array is a valid input for the UUID constructor.
  */
  to-byte-array -> ByteArray:
    return bytes_.copy

  /** Whether this instance has the same 128 bits as $other. */
  operator == other -> bool:
    if other is not Uuid: return false
    other-bytes := other.bytes_
    for i := 0; i < SIZE; i++:
      if bytes_[i] != other-bytes[i]: return false
    return true

  /** A hash code for this instance. */
  // The "randomness" of the UUID bytes is uniformly distributed
  // across all the bytes, so we just use the first three bytes
  // and stay in the small integer range.
  hash-code -> int:
    hash := hash_
    if hash: return hash
    else: return hash_ = bytes_[0] | bytes_[1] << 8 | bytes_[2] << 16

  /** Whether this instance is equal to the nil UUID $NIL. */
  is-nil -> bool: return not bytes_.any: it != 0
