// Copyright (C) 2026 Toit contributors.
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

import cli.cache as cli-cache
import encoding.json
import host.file

/**
Caches toitdoc JSON files on disk, backed by the CLI's $cli-cache.Cache.

Uses the CLI cache's file-locking mechanism for safe concurrent access.
  Cache entries are stored as JSON files under the "mcp/" prefix.
*/
class DocCache:
  cache_/cli-cache.Cache

  /**
  Creates a cache manager backed by the given CLI $cache.
  */
  constructor cache/cli-cache.Cache:
    cache_ = cache

  /**
  Returns cached toitdoc JSON for the given $key, or null if not cached.
  */
  get --key/string -> Map?:
    prefixed := prefixed-key_ key
    if not cache_.contains prefixed: return null
    exception := catch:
      content := file.read-contents (cache_.get-file-path prefixed)
      return json.decode content
    return null

  /**
  Ensures an entry exists in the cache under the given $key.

  If the entry already exists, the $block is not called (the existing
    entry is kept). This is correct for our use case since cache keys
    include version information.

  If the entry does not exist, the $block is called to produce the data,
    which is then stored.

  Uses the CLI cache's file store mechanism for atomic writes.
  */
  put --key/string [block] -> none:
    prefixed := prefixed-key_ key
    cache_.get-file-path prefixed: | store/cli-cache.FileStore |
      data/Map := block.call
      encoded := json.encode data
      store.save encoded

  /**
  Builds a cache key for SDK docs.
  */
  static sdk-key --version/string -> string:
    return "sdk-$version"

  /**
  Builds a cache key for package docs.

  The $id is the full package URL (e.g. "github.com/toitlang/pkg-http").
  Slashes in the ID are replaced with %2F for filesystem safety.
  */
  static package-key --id/string --version/string -> string:
    escaped := id.replace --all "/" "%2F"
    return "$escaped@$version"

  /** Adds the "mcp/" prefix to a cache $key. */
  prefixed-key_ key/string -> string:
    return "mcp/$(key).json"
