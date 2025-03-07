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
import io
import system
import system show platform
import ar show *
import tar show *

do-ctest exe-dir tmp-dir file-mapping --in-memory=false:
  tmp-path := "$tmp-dir/c_generated.a"
  generator-path := "$exe-dir/ar-generator"
  args := [
    generator-path,
    tmp-path,
  ]
  if in-memory: args.add "--memory"

  pipes := pipe.fork
      true                // use_path
      pipe.PIPE-CREATED   // stdin
      pipe.PIPE-INHERITED // stdout
      pipe.PIPE-INHERITED // stderr
      generator-path
      args
  to := pipes[0]
  pid := pipes[3]
  tar := Tar to
  file-mapping.do: |name content|
    tar.add name content
  tar.close --no-close-writer
  to.close
  exit-value := pipe.wait-for pid
  expect-equals null
    pipe.exit-signal exit-value
  expect-equals 0
    pipe.exit-code exit-value
  return file.read-contents tmp-path

extract archive-file contained-file -> ByteArray:
  // 'p' prints the $contained_file onto stdout.
  from := pipe.from "ar" "p" archive-file contained-file
  result := ByteArray 0
  reader := from.in
  while next := reader.read:
    result += next
  from.close
  return result

run-test file-mapping/Map tmp-dir [generate-ar]:
  ba := generate-ar.call tmp-dir file-mapping

  seen := {}
  count := 0
  ar-reader := ArReader (io.Reader ba)
  ar-reader.do: |file/ArFile|
    count++
    seen.add file.name
    expected := file-mapping[file.name]
    expect-equals expected file.contents
  // No file was seen twice.
  expect-equals seen.size count
  expect-equals file-mapping.size count

  seen = {}
  count = 0
  ar-reader = ArReader.from-bytes ba
  ar-reader.do --offsets: |file-offsets/ArFileOffsets|
    count++
    seen.add file-offsets.name
    expected := file-mapping[file-offsets.name]
    actual := ba.copy file-offsets.from file-offsets.to
    expect-equals expected actual
  // No file was seen twice.
  expect-equals seen.size count
  expect-equals file-mapping.size count

  ar-reader = ArReader (io.Reader ba)
  // We should find all files if we advance from top to bottom.
  last-name := null
  file-mapping.do: |name content|
    last-name = name
    file := ar-reader.find name
    expect-equals content file.contents

  ar-reader = ArReader.from-bytes ba
  // We should find all files if we advance from top to bottom.
  file-mapping.do: |name content|
    last-name = name
    file-offsets := ar-reader.find --offsets name
    actual := ba.copy file-offsets.from file-offsets.to
    expect-equals content actual

  ar-reader = ArReader (io.Reader ba)
  ar-file := ar-reader.find "not there"
  expect-null ar-file
  if last-name:
    ar-file = ar-reader.find last-name
    // We skipped over all files, so can't find anything anymore.
    expect-null ar-file

  if last-name:
    ar-reader = ArReader.from-bytes ba
    file := ar-reader.find last-name
    expect-not-null file
    // But now we can't find the same file anymore.
    file = ar-reader.find last-name
    expect-null file
    // In fact we can't find any file anymore:
    file-mapping.do: |name content|
      file = ar-reader.find name
      expect-null file

  // FreeRTOS doesn't have `ar`.
  if platform == system.PLATFORM-FREERTOS: return

  test-path := "$tmp-dir/test.a"
  stream := file.Stream.for-write test-path
  (io.Writer.adapt stream).write ba
  stream.close
  file-mapping.do: |name expected-content|
    actual := extract test-path name
    expect-equals expected-content actual

TESTS ::= [
  {:},
  {"odd": "odd".to-byte-array},
  {"even": "even".to-byte-array},
  {
    "even": "even".to-byte-array,
    "odd": "odd".to-byte-array,
  },
  {
    "odd": "odd".to-byte-array,
    "even": "even".to-byte-array,
  },
  {
    "binary": #[0, 1, 2, 255],
    "newlines": "\n\n\n\n".to-byte-array,
    "newlines2": "\a\a\a\a\a".to-byte-array,
    "big": ("the quick brown fox jumps over the lazy dog" * 1000).to-byte-array
  },
]

run-tests [generate-ar]:
  tmp-dir := directory.mkdtemp "/tmp/ar_test"
  try:
    TESTS.do: run-test it tmp-dir generate-ar
  finally:
    directory.rmdir --recursive tmp-dir

main args:
  // FreeRTOS doesn't run c tests.
  if platform == system.PLATFORM-FREERTOS: return

  exe-dir := args[0]
  run-tests: |tmp-dir file-mapping|
    do-ctest exe-dir tmp-dir file-mapping
  run-tests: |tmp-dir file-mapping|
    do-ctest exe-dir tmp-dir file-mapping --in-memory
