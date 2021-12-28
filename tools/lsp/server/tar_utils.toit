// Copyright (C) 2020 Toitware ApS. All rights reserved.

import host.file
import host.pipe
import bytes

find_tar_exec_:
  ["/bin/tar", "/usr/bin/tar"].do:
    if file.is_file it: return it
  throw "couldn't find tar"

tar_extract --binary/bool archive/string file_in_archive/string -> ByteArray:
  assert: binary == true
  tar_path := find_tar_exec_
  pipes := pipe.fork
      true
      pipe.PIPE_CREATED
      pipe.PIPE_CREATED
      pipe.PIPE_INHERITED
      tar_path
      [
        tar_path,
        "x",  // Extract.
        "-POf", // "P for absolute paths, to stdout, from file"
        archive,
        file_in_archive
      ]

  to := pipes[0]
  from := pipes[1]
  pid := pipes[3]
  result := bytes.Buffer
  try:
    while byte_array := from.read:
      result.write byte_array
  finally:
    from.close
    to.close
    pipe.dont_wait_for pid
  return result.bytes

tar_extract archive/string file_in_archive/string -> string:
  return (tar_extract --binary archive file_in_archive).to_string
