// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_allocate_doubles
  test_allocate_byte_arrays

test_allocate_doubles:
  x := 1.2
  allocated := List 5
  stats := List 5
  process_stats stats
  memory := stats[4]
  allocated.size.repeat:
    // Allocate one heap double.
    x *= 1.54
    process_stats stats
    diff := stats[4] - memory
    // A heap double is one word plus 8 bytes.
    expect
        diff == 16 or diff == 12
    allocated[it] = diff
    memory += diff
  allocated.do:
    print "Allocated $it"

  process_stats stats
  memory = stats[4]
  5_000.repeat:
    x += 1.54
    process_stats stats
    diff := stats[4] - memory
    expect
        diff == 16 or diff == 12
    memory += diff

test_allocate_byte_arrays:
  stats := List 5
  process_stats stats
  memory := stats[4]

  // One internal byte array.
  ba := ByteArray 400
  process_stats stats
  diff := stats[4] - memory
  memory += diff
  expect ba.size <= diff <= ba.size + 40

  // One external byte array.
  ba = ByteArray 40_000
  process_stats stats
  diff = stats[4] - memory
  memory += diff

  expect ba.size <= diff <= ba.size + 40
