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

import cli
import host.directory
import host.file

import .registry
import ..semantic-version
import ..file-system-view

class LocalRegistry extends Registry:
  type ::= "local"
  path/string

  constructor name/string .path/string --ui/cli.Ui:
    super name --ui=ui

  content -> FileSystemView:
    return FileSystemView_ path

  to-map -> Map:
    return  {
      "path": path,
      "type": type,
    }

  sync:

  to-string -> string:
    return "$path ($type)"

  stringify -> string:
    return "LocalRegistry(name: $name, path: $path)"

class FileSystemView_ implements FileSystemView:
  root/string

  constructor .root:

  get --path/List -> any:
    if path.is-empty: return null
    if path.size == 1: return get path[0]

    entry := "$root/$path[0]"
    if not file.is-directory entry: return null
    return (FileSystemView_ entry).get --path=path[1..]

  get key/string -> any:
    entry := "$root/$key"

    if not file.stat entry: return null

    if file.is-directory entry:
      return FileSystemView_ entry

    return file.read-contents entry

  list -> Map:
    result := {:}
    stream := directory.DirectoryStream root
    try:
      while next := stream.next:
        next_ := "$root/$next"
        if file.is-directory next_:
          result[next] = FileSystemView_ "$root/$next"
        else:
          result[next] = next
    finally:
      stream.close
    return result
