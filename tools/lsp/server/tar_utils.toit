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
import host.os
import io
import system

find-tar-exec_:
  if system.platform != system.PLATFORM-WINDOWS:
    ["/bin/tar", "/usr/bin/tar"].do:
      if file.is-file it: return it
    throw "couldn't find tar"

  // On Windows, we use the tar.exe that comes with Git for Windows.

  // TODO(florian): depending on environment variables is brittle.
  // We should use `SearchPath` (to find `git.exe` in the PATH), or
  // 'SHGetSpecialFolderPath' (to find the default 'Program Files' folder).
  program-files-path := os.env.get "ProgramFiles"
  if not program-files-path:
    // This is brittle, as Windows localizes the name of the folder.
    program-files-path = "C:/Program Files"
  result := "$program-files-path/Git/usr/bin/tar.exe"
  if not file.is-file result:
    throw "Could not find $result. Please install Git for Windows"
  return result

tar-extract --binary/bool archive/string file-in-archive/string -> ByteArray:
  assert: binary == true

  tar-path := find-tar-exec_

  extra-args := []
  if system.platform == system.PLATFORM-WINDOWS:
    // The Git tar can't handle backslashes as separators.
    archive = archive.replace --all "\\" "/"
    file-in-archive = file-in-archive.replace --all "\\" "/"
    // Treat 'c:\' as a local path.
    extra-args = ["--force-local"]

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
      ] + extra-args

  to := pipes[0]
  from := pipes[1]
  pid := pipes[3]
  result := io.Buffer
  try:
    result.write-from from.in
    pipe.wait-for pid
  finally:
    from.close
    to.close
  return result.bytes

tar-extract archive/string file-in-archive/string -> string:
  return (tar-extract --binary archive file-in-archive).to-string
