// Copyright (C) 2024 Toitware ApS.
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

import encoding.url
import fs

flatten_list input/List -> List:
  list := List
  input.do:
    if it is List: list.add-all (flatten_list it)
    else: list.add it
  return list

/**
Assumes that the values in $map are of type $List.

If the $key is in $map, append the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $List with the
  the one element being $value.
*/
append-to-list-value map/Map key value:
  list := map.get key --init=:[]
  list.add value

/**
Assumes that the values in $map are of type $Set.

If the $key is in $map, add the $value to the entry with $key.
If the $key is not in $map, create a new entry for $key as a size one $Set with the
  the one element being $value.
*/
add-to-set-value map/Map key value:
  set := map.get key --init=:{}
  set.add value

DANGEROUS-PATHS_ ::= {
  "",
  "CON", "PRN", "AUX", "NUL",
  "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
  "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
}

/** A platform-independent version of a path that is recognized by the compiler. */
to-uri-path path/string -> string:
  segments := fs.split path
  segments.map --in-place: | segment/string |
    segment = url.encode segment
    if DANGEROUS-PATHS_.contains segment.to-ascii-upper:
      // Escape the segment by adding a '%' at the end.
      // This ensures that the segment is a valid file name.
      // It's not a valid URL anymore, as the '%' is not a correct escape. However,
      // this also guarantees that we don't accidentally clash with any other
      // segment.
      segment = segment + "%"
    if segment.ends-with ".":
      segment = segment + "%"
    segment

  return segments.join "/"
