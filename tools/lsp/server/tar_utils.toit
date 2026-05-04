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
import io
import tar

tar-extract --binary/bool archive/string file-in-archive/string -> ByteArray:
  assert: binary == true

  stream := file.Stream.for-read archive
  try:
    reader := tar.Reader stream.in
    reader.do: | header/tar.Header content/ByteArray |
      if header.name == file-in-archive:
        return content
  finally:
    stream.close
  throw "File not found in archive: $file-in-archive"

tar-extract archive/string file-in-archive/string -> string:
  return (tar-extract --binary archive file-in-archive).to-string
