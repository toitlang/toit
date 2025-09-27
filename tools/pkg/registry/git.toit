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

import ar show ArReader ArWriter ArFile
import encoding.yaml
import fs
import host.file
import io

import cli
import cli.cache show FileStore

import ..git
import ..file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  static VERSION_ ::= "1.0.0"
  static VERSION-FILE_ ::= "VERSION"
  static PACK-FILE_ ::= "pack"
  static HASH-FILE_ ::= "hash"

  url/string
  ref-hash/string
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

  update-cache_ -> none
      --clear-cache/bool
      --sync/bool
      old-path/string?
      store/FileStore:
    hash := ref-hash or HEAD-INDICATOR_

    if clear-cache:
      // Act as if there was no old path, thus replacing the value.
      old-path=null

    repository/Repository? := null
    if old-path and file.is-file old-path:
      current-hash := hash
      if current-hash == HEAD-INDICATOR_:
        repository = open-repository url
        current-hash = repository.head
      old-contents := file.read-contents old-path
      old-hash/string := ?
      reader := ArReader (io.Reader old-contents)
      hash-file := reader.find HASH-FILE_
      if not hash-file:
        ui_.emit --warning "Invalid cache entry for registry $name at $old-path (missing $HASH-FILE_)"
      else:
        old-hash = hash-file.contents.to-string
        if old-hash == current-hash:
          // No need to update.
          return

    if not repository: repository = open-repository url
    if hash == HEAD-INDICATOR_: hash = repository.head
    ui_.emit --debug "Updating cache for registry $name at $url ($hash)"

    // TODO(floitsch): when the repository gets larger (several MB), it might be faster
    // to let the git server calculate the delta objects instead of downloading the full
    // pack.
    pack-data := repository.clone --binary hash
    buffer := io.Buffer
    ar-writer := ArWriter buffer
    ar-writer.add VERSION-FILE_ VERSION_
    ar-writer.add HASH-FILE_ hash
    ar-writer.add PACK-FILE_ pack-data
    store.save buffer.bytes

  load_ --sync/bool=false --clear-cache/bool=false -> FileSystemView:
    key := "registry/git/$url"

    ar-contents/ByteArray := ?
    if sync or clear-cache:
      ar-contents = cache.update key: | old-path/string store/FileStore |
        update-cache_ --clear-cache=clear-cache --sync=sync old-path store
    else:
      // By just doing a 'get' we avoid taking a file lock on the cache.
      ar-contents = cache.get key: | store/FileStore |
        update-cache_ --clear-cache=clear-cache --sync=sync null store

    ar-reader := ArReader (io.Reader ar-contents)
    has-checked-version := false

    hash/string? := null
    while true:
      entry := ar-reader.next
      if not entry:
        ui_.emit --warning "Invalid cache entry for registry $name at $key"
        return load_ --clear-cache

      if entry.name == VERSION-FILE_:
        version-string := entry.contents.to-string
        if version-string != VERSION_:
          ui_.emit --info "Updating cache for registry $name at $key from version $version-string to $VERSION_"
          return load_ --clear-cache
        has-checked-version = true
        continue

      if not has-checked-version:
        ui_.emit --warning "Invalid cache entry for registry $name at $key (missing $VERSION-FILE_)"
        return load_ --clear-cache

      if entry.name == HASH-FILE_:
        hash = entry.contents.to-string
        continue

      if not hash:
        ui_.emit --warning "Invalid cache entry for registry $name at $key (missing $HASH-FILE_)"
        return load_ --clear-cache

      if entry.name == PACK-FILE_:
        pack := Pack entry.contents hash
        return pack.content

      ui_.emit --warning "Ignoring unknown cache entry for registry $name at $key: $entry.name"

  sync --clear-cache/bool -> FileSystemView:
    content_ = load_ --sync --clear-cache=clear-cache
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
