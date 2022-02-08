// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

NEEDS_ENCODING_ ::= ByteArray '~' - '-' + 1:
  c := it + '-'
  (c == '-' or c == '_' or c == '.' or c == '~' or '0' <= c <= '9' or 'A' <= c <= 'Z' or 'a' <= c <= 'z') ? 0 : 1

// Takes an ASCII string or a byte array.
needs_encoding_ data -> int:
  count := 0
  data.do: | c |
    if not '-' <= c <= '~':
      count++
    else if NEEDS_ENCODING_[c - '-'] == 1:
      count++
  return count

// Takes an ASCII string or a byte array.
url_encode_ from -> any:
  escaped := needs_encoding_ from
  if escaped == 0: return from
  result := ByteArray from.size + escaped * 2
  pos := 0
  from.do: | c |
    if not '-' <= c <= '~' or NEEDS_ENCODING_[c - '-'] == 1:
      result[pos] = '%'
      result[pos + 1] = "0123456789ABCDEF"[c >> 4]
      result[pos + 2] = "0123456789ABCDEF"[c & 0xf]
      pos += 3
    else:
      result[pos++] = c
  return result

/**
Encodes the given $data using URL-encoding, also known as percent encoding.
The $data must be a string or byte array.  The value returned is a string or
  a byte array, but not necessarily of the same type as the $data.
The characters 0-9, A-Z, and a-z are unchanged by the encoding, as are the
  characters '-', '_', '.', and '~'.  All other characters are encoded in
  hexadecimal, using the percent sign.  Thus a space character is encode
  as "%20", and the Unicode snowman (☃) is encoded as "%E2%98%83".
*/
encode data -> any:
  if data is string:
    // If a string is ASCII only then the sizes match.
    if data.size != (data.size --runes):
      // Convert to something where do will iterate over UTF-8 bytes.
      data = data.to_byte_array
  else if data is not ByteArray:
    throw "WRONG_OBJECT_TYPE"
  return url_encode_ data
