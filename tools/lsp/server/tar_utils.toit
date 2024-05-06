// Copyright (C) 2020 Toitware ApS.
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

import host.file
import host.pipe
import io

find-tar-exec_:
  ["/bin/tar", "/usr/bin/tar"].do:
    if file.is-file it: return it
  throw "couldn't find tar"

tar-extract --binary/bool archive/string file-in-archive/string -> ByteArray:
  assert: binary == true
  tar-path := find-tar-exec_
  pipes := pipe.fork
      true
      pipe.PIPE-CREATED
      pipe.PIPE-CREATED
      pipe.PIPE-INHERITED
      tar-path
      [
        tar-path,
        "x",  // Extract.
        "-POf", // "P for absolute paths, to stdout, from file"
        archive,
        file-in-archive
      ]

  to := pipes[0]
  from := pipes[1]
  pid := pipes[3]
  result := io.Buffer
  try:
    result.write-from from
  finally:
    from.close
    to.close
    pipe.dont-wait-for pid
  return result.bytes

tar-extract archive/string file-in-archive/string -> string:
  return (tar-extract --binary archive file-in-archive).to-string
