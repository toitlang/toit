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
import host.file

import cli
import cli.cache show FileStore

import ..git
import ..file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  type ::= "git"
  url/string
  ref-hash/string? := null
  content_/FileSystemView? := null

  constructor name .url .ref-hash --ui/cli.Ui:
    super name --ui=ui

  content -> FileSystemView:
    if not ref-hash: content_ = sync
    else if not content_: content_ = load_
    return content_

  load_ -> FileSystemView:
    if ref-hash == HEAD-INDICATOR_:
      repository := open-repository url
      ref-hash = repository.head
    content := cache.get "registry/git/$(url)/$(ref-hash)" : | store/FileStore |
      repository := open-repository url
      pack-data := repository.clone --binary ref-hash
      store.save pack-data

    pack := Pack content ref-hash
    return pack.content

  sync -> FileSystemView:
    // TODO(mikkel): When the repository gets larger (several mb) it might be faster to let the git
    //               server calculate the delta objects instead of downloading the full pack file for the head-ref.
    repository := open-repository url
    ref-hash = repository.head
    return load_

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
