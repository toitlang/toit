// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Test that the C++ and Toit ar libraries can work together.
*/

import expect show *
import host.pipe
import host.directory
import host.file
import bytes
import ar show *
import tar show *
import writer show Writer

do_ctest exe_dir tmp_dir file_mapping --in_memory=false:
  tmp_path := "$tmp_dir/c_generated.a"
  generator_path := "$exe_dir/ar_generator"
  args := [
    generator_path,
    tmp_path,
  ]
  if in_memory: args.add "--memory"

  pipes := pipe.fork
      true                // use_path
      pipe.PIPE_CREATED   // stdin
      pipe.PIPE_INHERITED // stdout
      pipe.PIPE_INHERITED // stderr
      generator_path
      args
  to := pipes[0]
  pid  := pipes[3]
  tar := Tar to
  file_mapping.do: |name content|
    tar.add name content
  tar.close --no-close_writer
  to.close
  pipe.wait_for pid
  return file.read_content tmp_path

extract archive_file contained_file -> ByteArray:
  // 'p' prints the $contained_file onto stdout.
  from := pipe.from "ar" "p" archive_file contained_file
  result := ByteArray 0
  while next := from.read:
    result += next
  from.close
  return result

run_test file_mapping/Map tmp_dir [generate_ar]:
  ba := generate_ar.call tmp_dir file_mapping

  seen := {}
  count := 0
  ar_reader := ArReader (bytes.Reader ba)
  ar_reader.do: |file/ArFile|
    count++
    seen.add file.name
    expected := file_mapping[file.name]
    expect_equals expected file.content
  // No file was seen twice.
  expect_equals seen.size count
  expect_equals file_mapping.size count

  seen = {}
  count = 0
  ar_reader = ArReader.from_bytes ba
  ar_reader.do --offsets: |file_offsets/ArFileOffsets|
    count++
    seen.add file_offsets.name
    expected := file_mapping[file_offsets.name]
    actual := ba.copy file_offsets.from file_offsets.to
    expect_equals expected actual
  // No file was seen twice.
  expect_equals seen.size count
  expect_equals file_mapping.size count

  ar_reader = ArReader (bytes.Reader ba)
  // We should find all files if we advance from top to bottom.
  last_name := null
  file_mapping.do: |name content|
    last_name = name
    file := ar_reader.find name
    expect_equals content file.content

  ar_reader = ArReader.from_bytes ba
  // We should find all files if we advance from top to bottom.
  file_mapping.do: |name content|
    last_name = name
    file_offsets := ar_reader.find --offsets name
    actual := ba.copy file_offsets.from file_offsets.to
    expect_equals content actual

  ar_reader = ArReader (bytes.Reader ba)
  ar_file := ar_reader.find "not there"
  expect_null ar_file
  if last_name:
    ar_file = ar_reader.find last_name
    // We skipped over all files, so can't find anything anymore.
    expect_null ar_file

  if last_name:
    ar_reader = ArReader.from_bytes ba
    file := ar_reader.find last_name
    expect_not_null file
    // But now we can't find the same file anymore.
    file = ar_reader.find last_name
    expect_null file
    // In fact we can't find any file anymore:
    file_mapping.do: |name content|
      file = ar_reader.find name
      expect_null file

  // FreeRTOS doesn't have `ar`.
  if platform == "FreeRTOS": return

  test_path := "$tmp_dir/test.a"
  stream := file.Stream.for_write test_path
  (Writer stream).write ba
  stream.close
  file_mapping.do: |name expected_content|
    actual := extract test_path name
    expect_equals expected_content actual

TESTS ::= [
  {:},
  {"odd": "odd".to_byte_array},
  {"even": "even".to_byte_array},
  {
    "even": "even".to_byte_array,
    "odd": "odd".to_byte_array,
  },
  {
    "odd": "odd".to_byte_array,
    "even": "even".to_byte_array,
  },
  {
    "binary": #[0, 1, 2, 255],
    "newlines": "\n\n\n\n".to_byte_array,
    "newlines2": "\a\a\a\a\a".to_byte_array,
    "big": ("the quick brown fox jumps over the lazy dog" * 1000).to_byte_array
  },
]

run_tests [generate_ar]:
  tmp_dir := directory.mkdtemp "/tmp/ar_test"
  try:
    TESTS.do: run_test it tmp_dir generate_ar
  finally:
    directory.rmdir --recursive tmp_dir

main args:
  // FreeRTOS doesn't run c tests.
  if platform == "FreeRTOS": return

  exe_dir := args[0]
  run_tests: |tmp_dir file_mapping|
    do_ctest exe_dir tmp_dir file_mapping
  run_tests: |tmp_dir file_mapping|
    do_ctest exe_dir tmp_dir file_mapping --in_memory
