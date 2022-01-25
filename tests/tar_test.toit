// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import tar show *
import host.pipe
import host.file
import monitor

run_tar command flags [generator]:
  pipes := pipe.fork
      true
      pipe.PIPE_CREATED
      pipe.PIPE_CREATED
      pipe.PIPE_INHERITED
      "tar"
      [
        "tar", command, flags,
      ]

  to := pipes[0]
  from := pipes[1]
  pid := pipes[3]
  pipe.dont_wait_for pid

  // Process STDOUT in subprocess, so we don't block the tar process.
  latch := monitor.Latch
  task::
    result := ""
    while byte_array := from.read:
      result += byte_array.to_string  // Relies on us not having Unicode boundaries.
    latch.set result

  generator.call to
  // TODO(florian): it would be nicer if the generator closed the `to`.
  // However, we currently have difficulties knowing whether to call `close` or `close_write`.
  to.close

  return latch.get

inspect_with_tar_bin [generator]:
  return run_tar
      "t"   // list
      "-Pv" // P for absolute paths, verbose
      generator

/// Extracts the files in the generated file.
///
/// Returns the concatenated contents of all extracted files.
extract [generator]:
  return run_tar
      "x"   // extract
      "-PO" // P for absolute paths, to stdout
      generator

split_fields line/string -> List/*<string>*/:
  result := []
  start_pos := 0
  last_was_space := true
  for i := 0; i <= line.size; i++:
    c := i == line.size ? ' ' : line[i]
    if c == ' ' and not last_was_space:
      result.add (line.copy start_pos i)
    if c != ' ' and last_was_space:
      start_pos = i
    last_was_space = c == ' '
  return result

class TarEntry:
  name / string ::= ?
  size / int ::= -1

  constructor .name .size:

list_with_tar_bin [generator] -> List/*<TarEntry>*/:
  listing := inspect_with_tar_bin generator
  lines := (listing.trim --right "\n").split "\n"
  return lines.map: |line|
    // A line looks something like:
    // Linux: -rw-rw-r-- 0/0               5 1970-01-01 01:00 /foo
    // Mac:   -rw-rw-r--  0 0      0           5 Jan  1  1970 /foo
    name_index := platform == "macOS" ? 8 : 5
    size_index := platform == "macOS" ? 4 : 2
    components := split_fields line
    file_name := components[name_index]
    size := int.parse components[size_index]
    TarEntry file_name size

test_tar contents:
  create_tar := : |writer|
    tar := Tar writer
    contents.do: |file_name file_contents|
      tar.add file_name file_contents
    tar.close --no-close_writer

  listing := list_with_tar_bin create_tar
  expect_equals contents.size listing.size
  listing.do: |entry|
    expect (contents.contains entry.name)
    expect_equals entry.size contents[entry.name].size

  concatenated_content := extract create_tar
  expected := ""
  contents.do --values:
    expected += it
  expect_equals expected concatenated_content

create_huge_contents -> string:
  bytes := ByteArray 10000
  for i := 0; i < bytes.size; i++:
    bytes[i] = 'A' + i % 50
  return bytes.to_string

main:
  // FreeRTOS doesn't have `tar`.
  if platform == "FreeRTOS": return

  test_tar {
    "/foo": "12345",
  }

  test_tar {
    "/foo": "12345",
    "bar": "1",
  }

  test_tar {
    "/foo": "12345",
    "bar": "",
  }
  test_tar {
    "/foo/bar": "12345",
    "huge_file": create_huge_contents,
    "empty": "",
    "gee": "gee",
  }
