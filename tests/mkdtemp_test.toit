// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import host.directory
import host.file

main:
  // Make a temporary directory in the current dir.
  tmp_dir := directory.mkdtemp "foo-"
  print tmp_dir
  expect (file.is_directory tmp_dir)
  directory.rmdir tmp_dir

  // Make a temporary directory in the system dir.
  tmp_dir = directory.mkdtemp "/tmp/foo-"
  print tmp_dir
  expect (file.is_directory tmp_dir)
  directory.rmdir tmp_dir
