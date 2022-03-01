// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

NEEDS_ENCODING_ ::= ByteArray '~' - '-' + 1:
  c := it + '-'
  (c == '-' or c == '_' or c == '.' or c == '~' or '0' <= c <= '9' or 'A' <= c <= 'Z' or 'a' <= c <= 'z') ? 0 : 1

// Takes an ASCII string or a byte array.
// Counts the number of bytes that need escaping.
count_escapes_ data -> int:
  count := 0
  table := NEEDS_ENCODING_
  data.do: | c |
    if not '-' <= c <= '~':
      count++
    else if table[c - '-'] == 1:
      count++
  return count

// Takes an ASCII string or a byte array.
url_encode_ from -> any:
  escaped := count_escapes_ from
  if escaped == 0: return from
  result := ByteArray from.size + escaped * 2
  pos := 0
  table := NEEDS_ENCODING_
  from.do: | c |
    if not '-' <= c <= '~' or table[c - '-'] == 1:
      result[pos] = '%'
      result[pos + 1] = to_upper_case_hex c >> 4
      result[pos + 2] = to_upper_case_hex c & 0xf
      pos += 3
    else:
      result[pos++] = c
  return result.to_string

/**
Encodes the given $data using URL-encoding, also known as percent encoding.
The $data must be a string or byte array.  The value returned is a string or
  a byte array.  It can only be a byte array if the input was a byte array
  and in this case it can be the identical byte array that was passed in.
The characters 0-9, A-Z, and a-z are unchanged by the encoding, as are the
  characters '-', '_', '.', and '~'.  All other characters are encoded in
  hexadecimal, using the percent sign.  Thus a space character is encoded
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

/**
Decodes the given $data using URL-encoding, also known as percent encoding.
The function is liberal, accepting unencoded characters that should be
  encoded, with the exception of '%'.
Takes a string or a byte array, and may return a string or a ByteArray.
  (Both string and ByteArray have a to_string method.)
Does not check for malformed UTF-8, but calling to_string on the return
  value will throw on malformed UTF-8.
Plus signs (+) are not decoded to spaces.
# Example
  (url.decode "foo%20b%C3%A5r").to_string  // Returns "foo bår"
*/
decode data -> any:
  if data is string:
    if not data.contains "%": return data
    if data.size != (data.size --runes): data = data.to_byte_array
  else if data is ByteArray:
    if (data.index_of '%') == -1: return data
  else:
    throw "WRONG_OBJECT_TYPE"
  count := 0
  data.do: | c |
    if c == '%': count++
  result := ByteArray data.size - count * 2
  j := 0
  for i := 0; i < data.size; i++:
    c := data[i]
    if c == '%':
      c = (hex_digit data[i + 1]) << 4
      c += hex_digit data[i + 2]
      i += 2
    result[j++] = c
  return result
