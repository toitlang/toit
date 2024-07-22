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

import fs
import system
import system show platform

// Correctly canonicalized paths never have "///" in their path.
VIRTUAL-FILE-MARKER_ ::= "///"

to-hex-char_ x:
  if 0 <= x <= 9: return '0' + x
  return 'a' + x - 10

percent-encode_ str:
  encoded := ByteArray str.size * 3  // At most 3 times as big.
  target-i := 0
  for i := 0; i < str.size; i++:
    c := str.at --raw i
    if c == '/' or c == '.' or
        'a' <= c <= 'z' or
        'A' <= c <= 'Z' or
        '0' <= c <= '9':
      encoded[target-i++] = c
      continue
    encoded[target-i++] = '%'
    encoded[target-i++] = to-hex-char_ (c >> 4)
    encoded[target-i++] = to-hex-char_ (c & 0xF)
  if target-i == str.size: return  str
  return encoded.to-string 0 target-i

from-hex-char_ x:
  if '0' <= x <= '9': return x - '0'
  if 'a' <= x <= 'f': return 10 + x - 'a'
  assert: 'A' <= x <= 'F'
  return 10 + x - 'A'

percent-decode_ str:
  decoded := ByteArray str.size
  source-i := 0
  target-i := 0
  while source-i < str.size:
    c := str.at --raw source-i++
    if c == '%':
      unit := ((from-hex-char_ (str.at --raw source-i++)) << 4) +
          from-hex-char_ (str.at --raw source-i++)
      decoded[target-i++] = unit
    else:
      decoded[target-i++] = c
  if source-i == target-i: return str
  return decoded.to-string 0 target-i

to-uri path/string --from-compiler/bool=false -> string:
  if path.starts-with VIRTUAL-FILE-MARKER_:
    return path.trim --left VIRTUAL-FILE-MARKER_

  if platform == system.PLATFORM-WINDOWS and from-compiler:
    // The compiler keeps a '/' to know whether a path is absolute or not.
    assert: path.starts-with "/"
    path = path.trim --left "/"

  // As soon as there is a protocol/authority, the path must be absolute.
  // Here the protocol is "file://".
  // We would like to check that the path is absolute, but the compiler
  // works with a '/' in front, and might walk up the directory tree to
  // find the lock file. In that case it can remove the drive segment and
  // thus end up with a relative path.

  if platform == system.PLATFORM-WINDOWS:
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
  assert: path.starts-with "/"
  encoded := percent-encode_ path
  return "file://" + encoded

to-path uri/string --to-compiler/bool=false -> string:
  if uri.starts-with "file://":
    without-uri-prefix := uri.trim --left "file://"
    decoded := percent-decode_ without-uri-prefix
    if platform == system.PLATFORM-WINDOWS:
      if to-compiler:
        decoded = decoded.replace --all "\\" "/"
      else:
        // This should always be the case.
        // Remove the leading '/'.
        decoded = decoded.trim --left "/"
    return decoded
  // For every other uri assume that it's stored in the source-bundle and
  // mark it as virtual.
  return "$VIRTUAL-FILE-MARKER_$uri"

compiler-path-to-local-path compiler-path/string -> string:
  if platform == system.PLATFORM-WINDOWS:
    assert: compiler-path.starts-with "/"
    return compiler-path[1..].replace --all "/" "\\"
  return compiler-path

local-path-to-compiler-path local-path/string -> string:
  assert: fs.is-absolute local-path
  if platform == system.PLATFORM-WINDOWS:
    return "/$local-path"
  return local-path

/**
Returns a canonicalized version of the $uri.

Specifically deals with different ways of percent-encoding.
*/
canonicalize uri/string -> string: return to-uri (to-path uri)
