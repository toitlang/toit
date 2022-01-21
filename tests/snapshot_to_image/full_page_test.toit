// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes show Buffer
import host.directory
import expect show *
import host.file
import host.pipe
import writer show Writer

TOIT_PAGE_SIZE ::= 1 << 12

// A page has a header and the string itself takes up some bytes.
// Remove some bytes to be sure the string fits in a page.
// We are going to fill the rest with other objects anyway.
BIG_STRING_SIZE := TOIT_PAGE_SIZE - 256
BIG_STRING := "\"$("a" * BIG_STRING_SIZE)\""

VARIABLE_ELEMENT_COUNT ::= 800

toitc / string := ""
test_dir / string := ""
toit_file / string := ""
snap_file / string := ""
img_file  / string := ""

compile bigger_chunk_count small_string_size -> int:
  print "Compiling $bigger_chunk_count $small_string_size"
  content_prefix := """
    main:
      print ["""
  content_suffix := "]"
  buffer := Buffer
  buffer.write content_prefix
  // We always write a big string first. This forces the heap to go to a new
  // page. It's probably not really necessary, but can't hurt.
  buffer.write BIG_STRING
  buffer.write ","
  // We always want VARIABLE_ELEMENT_COUNT elements.
  // This is to ensure that the literal table is always of the same size.
  // If we had an array with different sizes, then the unmanaged memory would
  // have different sizes (because of the literal pointers, and because of the
  // bytecodes).
  VARIABLE_ELEMENT_COUNT.repeat:
    if it <= bigger_chunk_count:
      buffer.write "\"uses more space: $it\","
    else:
      buffer.write "$(it.to_float),"
  // As last element add the small string, which we will change byte by byte.
  // By binary search we will find the bigger_chunk_count that is on the verge
  // of triggering a bigger heap. That means that the small_string_size should
  // never need to be bigger than the diff between a float and the 'bigger'-string
  // chunks.
  buffer.write "\"$("x" * small_string_size)\","
  buffer.write content_suffix
  str :=  buffer.bytes.to_string

  stream := file.Stream.for_write toit_file
  (Writer stream).write str
  stream.close
  pipe.backticks toitc "-w" snap_file toit_file
  pipe.backticks toitc "-i" img_file snap_file
  return file.size img_file

// Tests that the image creation works when a heap page is completely full.
main args:
  i := 0
  ignored_snap := args[i++]
  toitc = args[i++]

  test_dir = directory.mkdtemp "/tmp/test-snapshot_to_image-"
  toit_file = "$test_dir/test.toit"
  snap_file = "$test_dir/test.snap"
  img_file = "$test_dir/test.img"

  try:
    small_string_size := 1
    starting_size := compile 0 small_string_size
    // Fill the program with floats, until it needs a new page.
    min := 0
    max := VARIABLE_ELEMENT_COUNT
    max_size := starting_size
    while true:
      if min + 1 >= max: break
      mid := (max + min) / 2
      current_size := compile mid small_string_size
      if current_size > starting_size:
        max = mid
        max_size = current_size
      else:
        min = mid
    expect max_size > starting_size
    expect_equals starting_size (compile min small_string_size)
    // At this point min has a smaller size than max.
    // Increment the small string's size, until we tip over again. This
    // should test the edge case.
    while true:
      small_string_size++
      current_size := compile min small_string_size
      if current_size > starting_size: break // Success.

  finally:
    directory.rmdir --recursive test_dir
