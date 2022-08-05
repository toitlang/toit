// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

DATA_256 := ((List 256: it).map: "$(%3d it), ").join ""

main args:
  out_file := args[0]
  size := int.parse args[1]

  data := "#["
  data_content := DATA_256
  while data_content.size < size * 5: data_content += data_content
  data += data_content[..size * 5]
  data += "]"
  content := """
  main:
    if DATA.size != $size: throw "BAD SIZE"
    indexes := [0, $size / 2, $size - 1]
    indexes.do:
      if DATA[it] != (it & 0xFF): throw "BAD DATA"

  DATA := $data
  """
  stream := file.Stream.for_write out_file
  written := 0
  while written != content.size:
    written += stream.write content[written..]
  stream.close
