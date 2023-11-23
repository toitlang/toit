// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE-ENDIAN
import bitmap
import reader show Reader BufferedReader
import .encoder
import .parser

export YamlEncoder

INITIAL-BUFFER-SIZE_ ::= 64
MAX-BUFFER-GROWTH_ ::= 1024

/**
Encodes the $obj as a YAML ByteArray.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $YamlEncoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $YamlEncoder.encode, $YamlEncoder.put-list,
  or $YamlEncoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
*/
encode obj [converter] -> ByteArray:
  e := YamlEncoder
  e.encode obj converter
  return e.to-byte-array

/**
Variant of $(encode obj [converter]).
Takes a lambda instead of a block as $converter.
*/
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

decode_ --as-stream/bool=false [--on-error] bytes/ByteArray -> any:
  p := Parser_ bytes
  result := p.l-yaml-stream --on-error=on-error
  if not result is ParseResult_: return result // This happens when on-error is invoked.
  documents := result.documents
  if as-stream: return documents
  if documents.is-empty: return null
  return documents[0]

/**
Decodes the $bytes, which is a ByteArray in single document YAML format.
The result is null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode [--on-error] bytes/ByteArray -> any:
  return decode_ --on-error=on-error bytes

/**
Variation of (decode --on-error bytes).

Throws on parse error.
*/
decode bytes/ByteArray -> any:
  return decode --on-error=(: throw it) bytes

/**
Decodes the $bytes, which is a ByteArray in YAML stream format.
The result is a $List where each elemenet in the list corresponds to a YAML document from the stream.
  Each element will be null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode --as-stream [--on-error] bytes/ByteArray -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ --as-stream --on-error=on-error bytes

/**
Variation of (decode --as-stream --on-error bytes).

Throws on parse error.
*/
decode --as-stream bytes/ByteArray -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ --as-stream --on-error=(: throw it) bytes


/**
Encodes the $obj as a YAML string.
The $obj must be a supported type, which means either a type supported
  by the $converter block or an instance of int, bool, float, string, List
  or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
The $converter block is passed an object to be serialized and an instance
  of the $YamlEncoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the YamlEncoder.encode, YamlEncoder.put-list,
  or YamlEncoder.put_unquoted methods on the encoder.
Utf-8 encoding is used for strings.
*/
stringify obj/any [converter] -> string:
  e := YamlEncoder
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
Decodes the $str, which is a string in single document YAML format.
The result is null or an instance of of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
parse [--on-error] str/string -> any:
  return decode_ --on-error=on-error str.to-byte-array

/**
Variation of (parse --on-error bytes).

Throws on parse error.
*/
parse str/string -> any:
  return parse --on-error=(: throw it ) str

/**
Decodes the $str, which is a string in YAML stream format.
The result is a $List where each elemenet in the list corresponds to a YAML document from the stream.
  Each element will be null or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
parse --as-stream [--on-error] str/string -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ --as-stream --on-error=on-error str.to-byte-array

/**
Variation of (parse --as-stream --on-error bytes).

Throws on parse error.
*/
parse --as-stream str/string -> List:
  return parse --as-stream --on-error=(: throw it ) str
