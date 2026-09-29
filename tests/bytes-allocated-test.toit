// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system show process-stats

main:
  test-allocate-doubles
  test-allocate-byte-arrays
  test-old-space-allocation
  test-cause-gc

ALLOCATED ::= system.STATS-INDEX-BYTES-ALLOCATED-IN-OBJECT-HEAP

test-allocate-doubles:
  x := 1.2
  allocated := List 5
  stats := List 5
  process-stats stats
  memory := stats[ALLOCATED]
  allocated.size.repeat:
    // Allocate one heap double.
    x *= 1.54
    process-stats stats
    diff := stats[ALLOCATED] - memory
    // A heap double is one word plus 8 bytes.
    expect
        diff == 16 or diff == 12
    allocated[it] = diff
    memory += diff
  allocated.do:
    print "Allocated $it"

  process-stats stats
  memory = stats[ALLOCATED]
  5_000.repeat:
    x += 1.54
    process-stats stats
    diff := stats[ALLOCATED] - memory
    expect
        diff == 16 or diff == 12
    memory += diff

test-allocate-byte-arrays:
  stats := List 5
  process-stats stats
  memory := stats[ALLOCATED]

  // One internal byte array.
  ba := ByteArray 400
  process-stats stats
  diff := stats[ALLOCATED] - memory
  memory += diff
  expect ba.size <= diff <= ba.size + 40

  // One external byte array.
  ba = ByteArray 40_000
  process-stats stats
  diff = stats[ALLOCATED] - memory
  memory += diff

  expect ba.size <= diff <= ba.size + 40

test-cause-gc:
  full-gcs := (process-stats)[system.STATS-INDEX-FULL-GC-COUNT]
  print "Full gcs: $full-gcs"
  new-full-gcs := (process-stats --gc)[system.STATS-INDEX-FULL-GC-COUNT]
  print "New full gcs: $new-full-gcs"
  expect new-full-gcs == full-gcs + 1

test-old-space-allocation:
  // Retaining half-page arrays fills new space and forces the primitive's
  // post-GC allocation retry directly into old space. That allocation must
  // count too; tracing/promotion of existing objects must not count again.
  page-size := system.platform == system.PLATFORM-FREERTOS ? 4096 : 32768
  size := page-size / 2
  retained := List 8
  stats := List 11
  process-stats --gc stats
  memory := stats[ALLOCATED]
  retained.size.repeat: | index |
    retained[index] = ByteArray size --initial=0x5a
    process-stats stats
    current := stats[ALLOCATED]
    expect (current - memory >= size) --message="Missing direct old-space allocation"
    memory = current
  process-stats --gc stats
  after := stats[ALLOCATED]
  expect (0 <= after - memory < 1024) --message="GC counted existing objects again"
  retained.do: | bytes/ByteArray |
    expect-equals size bytes.size
    expect-equals 0x5a bytes[0]
    expect-equals 0x5a bytes[size - 1]
