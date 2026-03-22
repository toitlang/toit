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

import encoding.yaml
import host.file

/**
Caches parsed package.lock data and re-parses when the file changes.

Supports lookup by package URL or by import prefix.
*/
class LockFileCache:
  project-root_/string
  lock-file-path_/string
  last-mtime_/any := null
  prefixes_/Map := {:}
  packages_/Map := {:}

  constructor .project-root_:
    lock-file-path_ = "$project-root_/package.lock"
    maybe-reload_

  /**
  Resolves the local file path for a package given its $url.

  Iterates package entries to find the one with the matching url field,
    then constructs the path from the .packages directory.
  */
  resolve-path --url/string -> string:
    maybe-reload_
    packages_.do: | _/string entry/Map |
      entry-url := entry.get "url"
      if entry-url == url:
        return resolve-entry-path_ entry
    throw "Package not found for URL: $url"

  /**
  Resolves the local file path for a package given its import $prefix.

  Looks up the prefix in the prefixes section, then reads the
    corresponding package entry.
  */
  resolve-path --prefix/string -> string:
    maybe-reload_
    package-key := prefixes_.get prefix
    if not package-key: throw "Unknown prefix: $prefix"
    entry := packages_.get package-key
    if not entry: throw "Package entry not found for prefix '$prefix' (key '$package-key')"
    return resolve-entry-path_ entry

  /**
  Resolves the version of a package given its $url.

  Returns null if the package is not found or is a local package.
  */
  resolve-version --url/string -> string?:
    maybe-reload_
    packages_.do: | _/string entry/Map |
      entry-url := entry.get "url"
      if entry-url == url:
        return entry.get "version"
    return null

  /**
  Resolves the version of a package given its import $prefix.

  Returns null if the prefix or package is not found, or if
    it is a local package.
  */
  resolve-version --prefix/string -> string?:
    maybe-reload_
    package-key := prefixes_.get prefix
    if not package-key: return null
    entry := packages_.get package-key
    if not entry: return null
    return entry.get "version"

  /**
  Constructs the filesystem path for a package $entry.

  For repository packages (with url and version), returns
    <project-root>/.packages/<url>/<version>.
  For local packages (with path), returns <project-root>/<path>.
  */
  resolve-entry-path_ entry/Map -> string:
    entry-path := entry.get "path"
    if entry-path:
      return "$project-root_/$entry-path"

    entry-url := entry["url"]
    entry-version := entry["version"]
    return "$project-root_/.packages/$entry-url/$entry-version"

  /**
  Reloads the lock file if the file has been modified since the last load.
  */
  maybe-reload_ -> none:
    if not file.is-file lock-file-path_:
      prefixes_ = {:}
      packages_ = {:}
      last-mtime_ = null
      return

    stat := file.stat lock-file-path_
    mtime := stat[file.ST-MTIME]
    if mtime == last-mtime_: return

    last-mtime_ = mtime
    contents/Map := (yaml.decode (file.read-contents lock-file-path_)) or {:}
    prefixes_ = contents.get "prefixes" --if-absent=: {:}
    packages_ = contents.get "packages" --if-absent=: {:}
