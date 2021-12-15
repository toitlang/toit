// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import host.file
import host.directory show *
import writer show Writer

expect_ name [code]:
  expect_equals
    name
    catch code

expect_out_of_bounds [code]:
  expect_ "OUT_OF_BOUNDS" code

expect_file_not_found [code]:
  expect_ "FILE_NOT_FOUND" code

expect_invalid_argument [code]:
  expect_ "INVALID_ARGUMENT" code

expect_already_closed [code]:
  expect_ "ALREADY_CLOSED" code

main:
  // This test does not work on ESP32 since there is no file system!
  if platform == "FreeRTOS": return

  expect_file_not_found: file.Stream.for_read "mkfxz.not_there"
  expect_file_not_found: file.Stream "mkfxz.not_there" file.RDONLY
  expect_invalid_argument: file.Stream "any name" file.CREAT       // Can't create a file without permissions.

  open_file := file.Stream.for_read "/dev/null"
  byte_array := open_file.read
  expect (not byte_array)
  open_file.close
  expect_already_closed: open_file.close

  open_file = file.Stream "/dev/null" file.RDONLY
  byte_array = open_file.read
  expect (not byte_array)
  open_file.close
  expect_already_closed: open_file.close

  test_contents := "This is the contents of the tæst file"

  tmpdir := mkdtemp "/tmp/toit_file_test_"

  try:

    test_recursive tmpdir

    chdir tmpdir

    test_recursive ""
    test_recursive "."

    filename := "test.out"
    dirname := "testdir"

    mkdir dirname

    try:
      test_out := file.Stream.for_write filename

      try:
        test_out.write test_contents
        test_out.close

        for i := 0; i < 10000; i++:
          file.read_content filename

        read_back := (file.read_content filename).to_string

        expect_equals test_contents read_back

        expect_equals test_contents.size (file.size filename)

      finally:
        file.delete filename

      test_out = file.Stream.for_write filename
      try:
        test_out.close
        expect_equals
          ByteArray 0
          file.read_content filename
      finally:
        file.delete filename

      expect (not file.size filename)

      test_out = file.Stream.for_write filename

      try:
        from := 5
        to := 7
        test_out.write test_contents from to
        test_out.close

        read_back := (file.read_content filename).to_string

        expect_equals (test_contents.copy from to) read_back

        expect_equals (to - from) (file.size filename)

      finally:
        file.delete filename

      expect (not file.size filename)

      cwd_path := cwd

      chdir dirname

      expect_equals "$cwd_path/$dirname" cwd

      expect_equals "$cwd_path/$dirname" (realpath ".")
      expect_equals "$cwd_path" (realpath "..")
      expect_equals "$cwd_path/$dirname" (realpath "../$dirname")
      expect_equals "$cwd_path" (realpath "../$dirname/..")
      expect_equals null (realpath "fætter");

      test_out = file.Stream filename file.CREAT | file.WRONLY 0x1ff
      test_out.write test_contents
      test_out.close

      expect_equals test_contents.size (file.size filename)
      chdir ".."
      expect_equals test_contents.size (file.size "$dirname/$filename")

      dir := DirectoryStream dirname
      name := dir.next
      expect name == filename
      expect (not dir.next)
      dir.close
      expect_already_closed: dir.close

      file.delete "$dirname/$filename"

    finally:
      rmdir dirname

  finally:
    rmdir tmpdir

test_recursive test_dir:
  // We want to test creation of paths if they are relative.
  rec_dir := test_dir == "" ? "rec" : "$test_dir/rec"

  deep_dir := "$rec_dir/a/b/c/d"
  mkdir --recursive deep_dir
  expect (file.is_directory deep_dir)

  paths := [
    "$rec_dir/foo",
    "$rec_dir/a/bar",
    "$rec_dir/a/b/gee",
    "$rec_dir/a/b/c/toto",
    "$rec_dir/a/b/c/d/titi",
  ]
  paths.do:
    stream := file.Stream.for_write it
    writer := (Writer stream)
    stream.write it
    stream.close

  paths.do:
    expect (file.is_file it)

  rmdir --recursive rec_dir
  expect (not file.stat rec_dir)
