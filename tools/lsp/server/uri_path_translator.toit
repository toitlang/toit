// Copyright (C) 2019 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

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
  to_uri path/string --from_compiler/bool=false -> string:
    if path.starts_with VIRTUAL_FILE_MARKER_:
      return path.trim --left VIRTUAL_FILE_MARKER_

    if platform == PLATFORM_WINDOWS and from_compiler:
      // The compiler keeps a '/' to know whether a path is absolute or not.
      assert: path.starts_with "/"
      path = path.trim --left "/"

    // As soon as there is a protocol/authority, the path must be absolute.
    // Here the protocol is "file://".
    if not is_absolute_ path:
      throw "Path must be absolute: $path"

    if platform == PLATFORM_WINDOWS:
      // CMake uses forward slashes in the source-bundle. However, the protocol
      // requires backslashes.
      path = path.replace --all "/" "\\"
      // RFC8089 states that a URI takes the form of 'file://host/path'.
      // The 'host' part is optional, in which case we end up with
      // three slashes.
      // The 'path' is always absolute, and on Linux, we don't add the
      // additional leading '/' for the root.
      // However, on Windows, we have to add the leading '/' to start the
      // path part.
      path = "/$path"
    assert: path.starts_with "/"
    encoded := percent_encode_ path
    return "file://" + encoded

  to_path uri/string --to_compiler/bool=false -> string:
    if uri.starts_with "file://":
      without_uri_prefix := uri.trim --left "file://"
      decoded := percent_decode_ without_uri_prefix
      if platform == PLATFORM_WINDOWS:
        if to_compiler:
          decoded = decoded.replace --all "\\" "/"
        else:
          // This should always be the case.
          // Remove the leading '/'.
          decoded = decoded.trim --left "/"
      return decoded
    // For every other uri assume that it's stored in the source-bundle and
    // mark it as virtual.
    return "$VIRTUAL_FILE_MARKER_$uri"

  compiler_path_to_local_path compiler_path/string -> string:
    if platform == PLATFORM_WINDOWS:
      assert: compiler_path.starts_with "/"
      return compiler_path[1..].replace --all "/" "\\"
    return compiler_path

  local_path_to_compiler_path local_path/string -> string:
    assert: is_absolute_ local_path
    if platform == PLATFORM_WINDOWS:
      return "/$local_path"
    return local_path

  /**
  Returns a canonicalized version of the $uri.

  Specifically deals with different ways of percent-encoding.
  */
  canonicalize uri/string -> string: return to_uri (to_path uri)

  is_absolute_ path/string -> bool:
    if path.starts_with "/": return true
    if platform == PLATFORM_WINDOWS:
      if path.starts_with "\\\\": return true
      if path.size >= 2 and path[1] == ':': return true
    return false
