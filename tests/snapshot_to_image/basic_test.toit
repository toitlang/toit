// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import host.pipe

main args:
  i := 0
  snap := args[i++]
  toitc := args[i++]
  snapshot_to_image := args[i++]

  test_dir := directory.mkdtemp "/tmp/test-snapshot_to_image-"
  s_file := "$test_dir/out.s"
  o_file := "$test_dir/out.o"

  try:
    // Run the snapshot-to-image tool.
    pipe.backticks toitc snapshot_to_image snap s_file
    // Run the assembler to verify that the output is correct.
    pipe.backticks "as" "-o" o_file s_file
  finally:
    directory.rmdir --recursive test_dir
