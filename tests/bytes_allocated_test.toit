// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_allocate_doubles
  test_allocate_byte_arrays
  test_cause_gc

ALLOCATED ::= STATS_INDEX_BYTES_ALLOCATED_IN_OBJECT_HEAP

test_allocate_doubles:
  x := 1.2
  allocated := List 5
  stats := List 5
  process_stats stats
  memory := stats[ALLOCATED]
  allocated.size.repeat:
    // Allocate one heap double.
    x *= 1.54
    process_stats stats
    diff := stats[ALLOCATED] - memory
    // A heap double is one word plus 8 bytes.
    expect
        diff == 16 or diff == 12
    allocated[it] = diff
    memory += diff
  allocated.do:
    print "Allocated $it"

  process_stats stats
  memory = stats[ALLOCATED]
  5_000.repeat:
    x += 1.54
    process_stats stats
    diff := stats[ALLOCATED] - memory
    expect
        diff == 16 or diff == 12
    memory += diff

test_allocate_byte_arrays:
  stats := List 5
  process_stats stats
  memory := stats[ALLOCATED]

  // One internal byte array.
  ba := ByteArray 400
  process_stats stats
  diff := stats[ALLOCATED] - memory
  memory += diff
  expect ba.size <= diff <= ba.size + 40

  // One external byte array.
  ba = ByteArray 40_000
  process_stats stats
  diff = stats[ALLOCATED] - memory
  memory += diff

  expect ba.size <= diff <= ba.size + 40

test_cause_gc:
  full_gcs := (process_stats)[STATS_INDEX_FULL_GC_COUNT]
  print "Full gcs: $full_gcs"
  new_full_gcs := (process_stats --gc)[STATS_INDEX_FULL_GC_COUNT]
  print "New full gcs: $new_full_gcs"
  expect new_full_gcs == full_gcs + 1
