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

import encoding.yaml
import fs
import host.file

import cli
import cli.cache show DirectoryStore

import ..git
import ..file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  static REGISTRY-PACK-FILE_ ::= "registry.pack"
  static HASH-FILE_ ::= "ref-hash.txt"

  url/string
  ref-hash/string? := null
  content_/FileSystemView? := null

  // The ref-hash is currently only used for testing.
  constructor name .url .ref-hash=HEAD-INDICATOR_ --ui/cli.Ui:
    super name --ui=ui

  operator == other -> bool:
    if not other is GitRegistry: return false
    return type == other.type and name == other.name and url == other.url and ref-hash == other.ref-hash

  type -> string: return "git"

  content -> FileSystemView:
    if not content_: content_ = load_
    return content_

  load_ --sync/bool=false -> FileSystemView:
    key := "registry/git/$url"

    repository/Repository? := null
    if sync and cache.contains key:
      repository = open-repository url
      if ref-hash == HEAD-INDICATOR_:
        ref-hash = repository.head
      path := cache.get-directory-path key: ui_.abort "Concurrent access to the registry cache detected."
      current-hash := (file.read-contents (fs.join path GitRegistry.HASH-FILE_)).to-string
      if current-hash != ref-hash:
        // Needs an update.
        // Delete the old entry.
        // TODO(florian): it would be nicer if we only deleted the old pack once we have the new one.
        cache.remove key

    path := cache.get-directory-path key: | store/DirectoryStore |
      repository = repository or open-repository url
      if ref-hash == HEAD-INDICATOR_:
        ref-hash = repository.head
      // TODO(floitsch): when the repository gets larger (several MB), it might be faster
      // to let the git server calculate the delta objects instead of downloading the full
      // pack.
      pack-data := repository.clone --binary ref-hash
      store.with-tmp-directory: | tmp-dir/string |
        file.write-contents pack-data --path=(fs.join tmp-dir REGISTRY-PACK-FILE_)
        file.write-contents "$ref-hash" --path=(fs.join tmp-dir HASH-FILE_)
        store.move tmp-dir

    pack-path := fs.join path REGISTRY-PACK-FILE_
    content := file.read-contents pack-path

    pack := Pack content ref-hash
    return pack.content

  sync -> FileSystemView:
    content_ = load_ --sync
    return content_

  to-map -> Map:
    return  {
      "url": url,
      "type": type,
      "ref-hash": ref-hash
    }

  to-string -> string:
    return "$url ($type)"

  stringify -> string:
    return "GitRegistry(name: $name, url: $url, ref-hash: $ref-hash)"
