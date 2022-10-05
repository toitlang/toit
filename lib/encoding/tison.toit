// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
The encoding format TISON is a binary encoded JSON variant similar
  to UBJSON.  It is natively supported by the Toit virtual machine
  and is fast to encode to and decode from.
*/

/**
Encodes the $object as a TISON $ByteArray.

The $object must be a supported type, which means an instance of int, bool,
  float, string, ByteArray, List or Map.  The elements of lists and the
  values of maps can be any of the supported types.

For compatibility with JSON encoding, you should avoid passing byte arrays
  directly or indirectly to $encode.

For compatibility with JSON and UBJSON encodings, you should avoid passing
  maps with non-string keys directly or indirectly to $encode.

Cannot encode data structures with cycles in them.  In this case it will
  throw "NESTING_TOO_DEEP".
*/
encode object/any -> ByteArray:
  #primitive.encoding.tison_encode:
    if it is int:
      serialization_failure_ it
    throw it

/**
Decodes $bytes, which is a $ByteArray in TISON format.

The result is null or an instance of int, bool, float, string, ByteArray,
  List, or Map.  The list elements and map values will also be one of
  these types.
*/
decode bytes/ByteArray -> any:
  #primitive.encoding.tison_decode
