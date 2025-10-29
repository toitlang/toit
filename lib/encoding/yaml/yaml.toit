// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap
import io
import io show LITTLE-ENDIAN
import .encoder
import .parser

export YamlEncoder

INITIAL-BUFFER-SIZE_ ::= 64
MAX-BUFFER-GROWTH_ ::= 1024

/**
Variant of $(encode obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $YamlEncoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $YamlEncoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $YamlEncoder.encode, $YamlEncoder.put-list,
  or $YamlEncoder.put-unquoted methods on the encoder.
*/
encode obj [converter] -> ByteArray:
  buffer := io.Buffer
  e := YamlEncoder.private_ buffer
  e.encode obj converter
  return buffer.bytes

/**
Variant of $(encode obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
encode obj converter/Lambda -> ByteArray:
  return encode obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML ByteArray.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
UTF-8 encoding is used for strings.
*/
encode obj -> ByteArray:
  return encode obj: throw "INVALID_YAML_OBJECT"

/**
Variant of $(encode-stream --writer obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $YamlEncoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $YamlEncoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $YamlEncoder.encode, $YamlEncoder.put-list,
  or $YamlEncoder.put-unquoted methods on the encoder.
*/
encode-stream --writer/io.Writer obj [converter] -> none:
  e := YamlEncoder.private_ writer
  e.encode obj converter

/**
Variant of $(encode-stream --writer obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
encode-stream --writer/io.Writer obj converter/Lambda -> none:
  encode-stream --writer=writer obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj onto an $io.Writer in YAML format.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
UTF-8 encoding is used on the writer.
*/
encode-stream --writer/io.Writer obj -> none:
  encode-stream --writer=writer obj: throw "INVALID_YAML_OBJECT"

decode_ bytes/ByteArray --as-stream/bool=false [--if-error] -> any:
  p := Parser_ bytes
  result := p.l-yaml-stream --if-error=if-error
  if not result is ParseResult_: return result // This happens when if-error is invoked.
  documents := result.documents
  if as-stream: return documents
  if documents.is-empty: return null
  return documents[0]

/** Deprecated. Use $(decode bytes [--if-error]) instead. */
decode bytes/ByteArray [--on-error] -> any:
  return decode bytes --if-error=on-error

/**
Decodes the $bytes, which is a ByteArray in single document YAML format.
The result is null, or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode bytes/ByteArray [--if-error] -> any:
  return decode_ bytes --if-error=if-error

/**
Variation of $(decode bytes [--if-error]).

Throws on parse error.
*/
decode bytes/ByteArray -> any:
  return decode --if-error=(: throw it) bytes

/** Deprecated. Use $(decode bytes --as-stream [--if-error]) instead. */
decode bytes/ByteArray --as-stream [--on-error]-> List:
  return decode bytes --as-stream --if-error=on-error

/**
Decodes the $bytes, which is a ByteArray in YAML stream format.
The result is a $List where each elemenet in the list corresponds to a YAML document from the stream.
  Each element will be null, or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
decode bytes/ByteArray --as-stream [--if-error] -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ --as-stream --if-error=if-error bytes

/**
Variation of $(decode bytes --as-stream [--if-error]).

Throws on parse error.
*/
decode --as-stream bytes/ByteArray -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ --as-stream --if-error=(: throw it) bytes


/**
Variant of $(stringify obj).
If the $obj is or contains a non-supported type, then the converter
  block is called with the object and an instance of the $YamlEncoder class.
  The converter is not called for map keys, which must still be strings.
The $converter block is passed an object to be serialized and an instance
  of the $YamlEncoder class.  If it returns a non-null value, that value will
  be serialized instead of the object that was passed in.  Alternatively,
  the $converter block can call the $YamlEncoder.encode, $YamlEncoder.put-list,
  or $YamlEncoder.put-unquoted methods on the encoder.
*/
stringify obj/any [converter] -> string:
  buffer := io.Buffer
  e := YamlEncoder.private_ buffer
  e.encode obj converter
  return buffer.to-string

/**
Variant of $(stringify obj [converter]).
Takes a $Lambda instead of a block as $converter.
*/
stringify obj converter/Lambda -> string:
  return stringify obj: | obj encoder | converter.call obj encoder

/**
Encodes the $obj as a YAML string.
The $obj must be a supported type, which means null, or an instance of int,
  bool, float, string, List or Map.
Maps must have only string keys.  The elements of lists and the values of
  maps can be any of the above supported types.
*/
stringify obj/any -> string:
  return stringify obj: throw "INVALID_YAML_OBJECT"

/** Deprecated. Use $(parse str [--if-error]) instead. */
parse str/string [--on-error] -> any:
  return parse str --if-error=on-error

/**
Decodes the $str, which is a string in single document YAML format.
The result is null, or an instance of of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
parse str/string [--if-error] -> any:
  return decode_ str.to-byte-array --if-error=if-error

/**
Variation of $(parse bytes [--if-error]).

Throws on parse error.
*/
parse str/string -> any:
  return parse str --if-error=(: throw it )

/** Deprecated. Use $(parse str --as-stream [--if-error]) instead. */
parse str/string --as-stream [--on-error] -> List:
  return parse str --as-stream --if-error=on-error

/**
Decodes the $str, which is a string in YAML stream format.
The result is a $List where each elemenet in the list corresponds to a YAML document from the stream.
  Each element will be null, or an instance of int, bool, float, string, List, or Map.
  The list elements and map values will also be one of these types.
*/
parse str/string --as-stream [--if-error] -> List:
  if not as-stream: throw "INVALID_ARGUMENT"
  return decode_ str.to-byte-array --as-stream --if-error=if-error

/**
Variation of $(parse bytes --as-stream [--if-error]).

Throws on parse error.
*/
parse --as-stream str/string -> List:
  return parse str --as-stream --if-error=(: throw it )
