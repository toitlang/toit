// Copyright (C) 2019 Toitware ApS. All rights reserved.

// Correctly canonicalized paths never have "///" in their path.
VIRTUAL_FILE_MARKER_ ::= "///"

to_hex_char_ x:
  if 0 <= x <= 9: return '0' + x
  return 'a' + x - 10

percent_encode_ str:
  encoded := ByteArray str.size * 3  // At most 3 times as big.
  target_i := 0
  for i := 0; i < str.size; i++:
    c := str.at --raw i
    if c == '/' or c == '.' or
        'a' <= c <= 'z' or
        'A' <= c <= 'Z' or
        '0' <= c <= '9':
      encoded[target_i++] = c
      continue
    encoded[target_i++] = '%'
    encoded[target_i++] = to_hex_char_ (c >> 4)
    encoded[target_i++] = to_hex_char_ (c & 0xF)
  if target_i == str.size: return  str
  return encoded.to_string 0 target_i

from_hex_char_ x:
  if '0' <= x <= '9': return x - '0'
  if 'a' <= x <= 'f': return 10 + x - 'a'
  assert: 'A' <= x <= 'F'
  return 10 + x - 'A'

percent_decode_ str:
  decoded := ByteArray str.size
  source_i := 0
  target_i := 0
  while source_i < str.size:
    c := str.at --raw source_i++
    if c == '%':
      unit := ((from_hex_char_ (str.at --raw source_i++)) << 4) +
          from_hex_char_ (str.at --raw source_i++)
      decoded[target_i++] = unit
    else:
      decoded[target_i++] = c
  if source_i == target_i: return str
  return decoded.to_string 0 target_i

/** Converts between LSP URIs and toitc paths. */
class UriPathTranslator:
  path_mapping_ /Map/*<string, string>*/ ::= ?

  constructor this.path_mapping_={"file://" : ""}:

  to_uri path/string -> string:
    if path.starts_with VIRTUAL_FILE_MARKER_:
      return path.trim --left VIRTUAL_FILE_MARKER_

    path_mapping_.do: | uri_prefix path_prefix |
      if path.starts_with path_prefix:
        without_path_prefix := path.trim --left path_prefix
        encoded := percent_encode_ without_path_prefix
        return uri_prefix + encoded
    assert: path.starts_with "/"
    return path.trim --left "/"

  to_path uri/string -> string:
    path_mapping_.do: | uri_prefix path_prefix |
      if uri.starts_with uri_prefix:
        without_uri_prefix := uri.trim --left uri_prefix
        decoded := percent_decode_ without_uri_prefix
        return path_prefix + decoded
    // For every other uri assume that it's stored in the source-bundle and
    // mark it as virtual.
    return "$VIRTUAL_FILE_MARKER_$uri"

  // Returns a canonicalized version of the uri.
  canonicalize uri/string -> string: return to_uri (to_path uri)
