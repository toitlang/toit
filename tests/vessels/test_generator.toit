// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

/**
Test file generator.

Generates a Toit file that contains a byte array of the given size.
This way we can create arbitrary big snapshots.
*/

// Create a string of the numbers from 0 to 256.
// Each entry is 5 characters long: 3 for the digits, followed by a comma and a space.
// The string starts with: "  0,   1,   2,  3,   4,   5,   6,   7,   8,   9,  10,  11, "
DATA_256 := ((List 256: it).map: "$(%3d it), ").join ""

main args:
  out_file := args[0]
  size := int.parse args[1]

  // Build a Toit byte-array string of the given size.
  // We use the precomputed string of 256 numbers and double it up until we have
  // at least the desired size. Then we cut off the part we don't need.
  // After the loop we have a a string consisting of the Toit code: "#[  1,   2, ...]"
  data := "#["
  data_content := DATA_256
  // Each entry in the precomputed string is 5 characters long.
  while data_content.size < size * 5: data_content += data_content
  data += data_content[..size * 5]
  data += "]"

  // Build the test-file content.
  // We just create `main` function that checks that 3 entries is the byte-array are
  // correct.
  content := """
  main:
    if DATA.size != $size: throw "BAD SIZE"
    indexes := [0, $size / 2, $size - 1]
    indexes.do:
      if DATA[it] != (it & 0xFF): throw "BAD DATA"

  DATA := $data
  """

  // Write the content into the given file.
  stream := file.Stream.for_write out_file
  written := 0
  while written != content.size:
    written += stream.write content[written..]
  stream.close
