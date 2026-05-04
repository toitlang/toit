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
import host.file
import host.directory
import fs
import system

flatten-list input/List -> List:
  list := List
  input.do:
    if it is List: list.add-all (flatten-list it)
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

/**
Escapes the given $path so it's valid.
Escapes '\' even if the platform is Windows, where it's a valid
  path separator.
If two given paths are equal, then the escaped paths are also equal.
If they are different, then the escaped paths are also different.
*/
escape-path path/string -> string:
  if system.platform != system.PLATFORM-WINDOWS:
    return path
  // On Windows, we need to escape some characters.
  // We use '#' as escape character.
  // We will treat '/' as the folder separator, and escape '\'.
  escaped-path := path.replace --all "#" "##"
  // The following characters are not allowed:
  //  <, >, :, ", |, ?, *
  // '\' and '/' would both become folder separators, so
  // we escape '\' to stay unique.
  // We escape them as #<hex value>.
  [ '<', '>', ':', '"', '|', '?', '*', '\\' ].do:
    escaped-path = escaped-path.replace --all
        string.from-rune it
        "#$(%02X it)"
  if escaped-path.ends-with " " or escaped-path.ends-with ".":
    // Windows doesn't allow files to end with a space or a dot.
    // Add a suffix to make it valid.
    // Note that this still guarantees uniqueness, because
    // a space would normally not be escaped.
    escaped-path = "$escaped-path#20"
  return escaped-path

/**
Makes the given $path read-only.

If $recursive is true and $path is a directory, makes all files and
  directories within $path read-only as well.
*/
make-read-only_ --recursive/bool path/string -> none:
  if not recursive or file.is-file path:
    stat := file.stat path
    if not stat:
      return
    mode := stat[file.ST-MODE]
    if system.platform == system.PLATFORM-WINDOWS:
      read-only-bit := file.WINDOWS-FILE-ATTRIBUTE-READONLY
      if (mode & read-only-bit) != 0: return
      file.chmod path (mode | read-only-bit)
      return
    write-bits := 0b010_010_010
    if (mode & write-bits) == 0: return
    file.chmod path (mode & ~write-bits)
    return

  // If it's not a directory, just ignore it.
  if not file.is-directory path: return

  stream := directory.DirectoryStream path
  while child := stream.next:
    make-read-only_ --recursive (fs.join path child)
  make-read-only_ --no-recursive path
