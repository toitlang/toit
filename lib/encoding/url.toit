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
      c = (hex_char_to_value data[i + 1]) << 4
      c += hex_char_to_value data[i + 2]
      i += 2
    result[j++] = c
  return result

/**
A $QueryString is a part of a uniform resource locator (URL) that assigns
  values to specified parameters. It fits between the resource parts and
  the fragment part in the URL encoding:

  https://example.com/over/there?name=ferret#fish

The query part starts at the '?' character and ends at the start of the
  fragment part (if any). The fragment part starts at the '#' character.
  The encoding of the query part uses the application/x-www-form-urlencoded
  content type.

For convenience, the $QueryString collects any resource parts (scheme,
  authority, and path) as $QueryString.resource and the fragment as
  $QueryString.fragment.
*/
class QueryString:
  resource/string
  parameters/Map
  fragment/string
  constructor.internal_ --.resource --.parameters --.fragment:

  /**
  Parses an $input string into a $QueryString by following the steps
    from https://url.spec.whatwg.org/#urlencoded-parsing and collects
    the resource parts and the fragment part as part of the parsing.

  The resource parts (scheme, authority, and path) and the fragment part
    are left unparsed, so $QueryString.parse supports partial URLs, like
    the ones where the the scheme and authority have been stripped.
  */
  static parse input/string -> QueryString:
    fragment := ""
    hash := input.index_of "#"
    if hash >= 0:
      fragment = input[hash + 1 ..]
      input = input[..hash]

    resource := input
    parameters := {:}
    question := input.index_of "?"
    if question >= 0:
      resource = input[..question]
      query := input[question + 1 ..]
      query.split "&" --drop_empty: | component/string |
        assign := component.index_of "="
        key/string := ?
        value/string := ?
        if assign >= 0:
          key = (decode component[..assign]).to_string
          value = (decode component[assign + 1 ..]).to_string
        else:
          key = (decode component).to_string
          value = ""
        existing := parameters.get key
        if existing is string:
          parameters[key] = [existing, value]
        else if existing is List:
          existing.add value
        else:
          parameters[key] = value

    return QueryString.internal_
        --resource=(decode resource).to_string
        --parameters=parameters
        --fragment=(decode fragment).to_string
