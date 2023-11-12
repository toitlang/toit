// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE-ENDIAN
import bitmap
import reader show Reader BufferedReader
import .encoder
import .parser

INITIAL-BUFFER-SIZE_ ::= 64
MAX-BUFFER-GROWTH_ ::= 1024

/**
Encodes the $obj as a YANL ByteArray.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or Encoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
*/
encode obj [converter] -> ByteArray:
  e := YamlEncoder_
  e.encode obj converter
  return e.to-byte-array

encode obj converter/Lambda -> ByteArray:
  return encode obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML ByteArray.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
Utf-8 encoding is used for strings.
*/
encode obj -> ByteArray:
  return encode obj: throw "INVALID_YAML_OBJECT"

/**
Decodes the $bytes, which is a ByteArray in YAML format.
The result is null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
Only a subset of YAML is supported.
*/
decode bytes/ByteArray -> any:
  p := Parser_ bytes
  documents := p.l-yaml-stream
  if documents.is-empty: return null
  return documents[0]

/**
Encodes the $obj as a YAML string.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $Encoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $Encoder.encode, $Encoder.put-list,
  or Encoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
Only a subset of YAML is supported.
*/
stringify obj/any [converter] -> string:
  e := YamlEncoder_
  e.encode obj converter
  return e.to-string

stringify obj converter/Lambda -> string:
  return stringify obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML string.
The $obj must be null or an instance of int, bool, float, string, List, or Map.
  Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
*/
stringify obj/any -> string:
  return stringify obj: throw "INVALID_YAML_OBJECT"

/**
Decodes the $str, which is a string in YAML format.
The result is null or an instance of of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
Only a subset of YAML is supported.
*/
parse str/string:
  return decode str.to-byte-array
