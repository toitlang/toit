// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary show LITTLE_ENDIAN

decode assets/ByteArray=assets_ -> Map:
  result := {:}
  if assets.is_empty: return result
  // Run through the entries and build the map.
  offset := 0
  marker := LITTLE_ENDIAN.uint32 assets offset
  offset += 4
  if marker != MARKER_:
    throw "cannot decode assets - wrong marker (0x$(%x marker) != 0x$(%x MARKER_))"
  entries_size := LITTLE_ENDIAN.uint32 assets offset
  offset += 4
  entries_size.repeat: | index/int |
    name_size := LITTLE_ENDIAN.uint32 assets offset
    offset += 4
    name := assets[offset..offset + name_size]
    offset += round_up name_size 4
    content_size := LITTLE_ENDIAN.uint32 assets offset
    offset += 4
    content := assets[offset..offset + content_size]
    offset += round_up content_size 4
    result[name.to_string] = content
  return result

encode entries/Map -> ByteArray:
  // First compute the size. This allows us to allocate
  // the resulting byte array in one go.
  size := 8
  entries.do: | name/string content/ByteArray |
    size += 4
    size += round_up name.size 4
    size += 4
    size += round_up content.size 4
  result := ByteArray size
  // Fill in the entries by running through the map again.
  offset := 0
  LITTLE_ENDIAN.put_uint32 result offset MARKER_
  offset += 4
  LITTLE_ENDIAN.put_uint32 result offset entries.size
  offset += 4
  entries.do: | name/string content/ByteArray |
    LITTLE_ENDIAN.put_uint32 result offset name.size
    offset += 4
    result.replace offset name
    offset += round_up name.size 4
    LITTLE_ENDIAN.put_uint32 result offset content.size
    offset += 4
    result.replace offset content
    offset += round_up content.size 4
  return result

// ----------------------------------------------------------------------------

MARKER_ / int ::= 0x6395f9f1

assets_ -> ByteArray:
  #primitive.programs_registry.assets
