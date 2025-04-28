// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import expect show *
import io show Buffer Writer
import host.file
import host.pipe

TOIT-PAGE-SIZE ::= 1 << 12

// A page has a header and the string itself takes up some bytes.
// Remove some bytes to be sure the string fits in a page.
// We are going to fill the rest with other objects anyway.
BIG-STRING-SIZE := TOIT-PAGE-SIZE - 256
BIG-STRING := "\"$("a" * BIG-STRING-SIZE)\""

VARIABLE-ELEMENT-COUNT ::= 800

toitrun           / string := ""
snapshot-to-image / string := ""

test-dir  / string := ""
toit-file / string := ""
snap-file / string := ""
img-file  / string := ""

compile bigger-chunk-count small-string-size -> int:
  print "Compiling $bigger-chunk-count $small-string-size"
  // We don't run the image here, but as a general principle don't use 'print'
  // in image tests as it might require a boot-snapshot.
  content-prefix := """
    main:
      print_ ["""
  content-suffix := "]"
  buffer := Buffer
  buffer.write content-prefix
  // We always write a big string first. This forces the heap to go to a new
  // page. It's probably not really necessary, but can't hurt.
  buffer.write BIG-STRING
  buffer.write ","
  // We always want VARIABLE_ELEMENT_COUNT elements.
  // This is to ensure that the literal table is always of the same size.
  // If we had an array with different sizes, then the unmanaged memory would
  // have different sizes (because of the literal pointers, and because of the
  // bytecodes).
  VARIABLE-ELEMENT-COUNT.repeat:
    if it <= bigger-chunk-count:
      buffer.write "\"uses more space: $it\","
    else:
      buffer.write "$(it.to-float),"
  // As last element add the small string, which we will change byte by byte.
  // By binary search we will find the bigger_chunk_count that is on the verge
  // of triggering a bigger heap. That means that the small_string_size should
  // never need to be bigger than the diff between a float and the 'bigger'-string
  // chunks.
  buffer.write "\"$("x" * small-string-size)\","
  buffer.write content-suffix
  str :=  buffer.bytes.to-string

  stream := file.Stream.for-write toit-file
  (Writer.adapt stream).write str
  stream.close
  pipe.run-program [toitrun, "-w", snap-file, toit-file]
  pipe.run-program [toitrun, snapshot-to-image, "--format", "binary", "-o", img-file, snap-file]
  return file.size img-file

// Tests that the image creation works when a heap page is completely full.
main args:
  i := 0
  ignored-snap := args[i++]
  toitrun = args[i++]
  snapshot-to-image = args[i++]

  test-dir = directory.mkdtemp "/tmp/test-snapshot_to_image-"
  toit-file = "$test-dir/test.toit"
  snap-file = "$test-dir/test.snap"
  img-file = "$test-dir/test.img"

  try:
    small-string-size := 1
    starting-size := compile 0 small-string-size
    // Fill the program with floats, until it needs a new page.
    min := 0
    max := VARIABLE-ELEMENT-COUNT
    max-size := starting-size
    while true:
      if min + 1 >= max: break
      mid := (max + min) / 2
      current-size := compile mid small-string-size
      if current-size > starting-size:
        max = mid
        max-size = current-size
      else:
        min = mid
    expect max-size > starting-size
    expect-equals starting-size (compile min small-string-size)
    // At this point min has a smaller size than max.
    // Increment the small string's size, until we tip over again. This
    // should test the edge case.
    while true:
      small-string-size++
      current-size := compile min small-string-size
      if current-size > starting-size: break // Success.

  finally:
    directory.rmdir --recursive test-dir
