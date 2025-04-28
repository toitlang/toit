// Copyright (C) 2023 Toitware ApS.
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
import host.file
import system
import .uri-path-translator as translator

/**
Computes the project URI for a given path.

If the $uri is not absolute uses `/` instead. The compiler is
  not supposed to use the project URI in that case.

The project URI is the path that contains a `package.{yaml|lock}` file.
However, it must not be inside a '.packages' folder. In that case we assume that
there is a `package.{yaml|lock}` file in the parent folder.
*/
compute-project-uri --uri/string -> string:
  path := translator.to-path uri
  if not fs.is-absolute path:
    return translator.to-uri "/"

  dir := fs.dirname path

  slash-dir := dir.replace --all "\\" "/"
  segments := slash-dir.split "/"
  dot-packages-index := segments.index-of --last ".packages"

  if dot-packages-index != -1:
    // We don't even check whether there is a package.yaml|lock file.
    // We just assume that this is the project uri.
    result-path := segments[..dot-packages-index].join "/"
    return translator.to-uri result-path

  while true:
    if file.is-file "$dir/package.yaml" or file.is-file "$dir/package.lock":
      return translator.to-uri dir
    parent := fs.dirname dir
    if parent == dir:
      // We have reached the root directory (or the current directory if the
      // path is relative).
      return translator.to-uri dir
    dir = parent
