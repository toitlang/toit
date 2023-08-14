// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that we don't go quadratic in running time when using sets and maps as
// queues or FIFOs, ie always removing the oldest or newest entries first.
// Runs in < 1.4s on release and <3.0s on debug.
main:
  size := platform == "FreeRTOS" ? 2048 : 80000
  print "set_test_first"
  set-test-first size
  print "map_test_first"
  map-test-first size
  print "set_test_last"
  set-test-last size
  print "map_test_last"
  map-test-last size
  print "set_test_index_clogged"
  set-test-index-clogged size / 2

set-test-first n:
  s := {}
  n.repeat: s.add (random 0 n)
  while s.size != 0:
    s.remove s.first

map-test-first n:
  m := {:}
  n.repeat:
    r := random 0 n
    m[r] = r
  while m.size != 0:
    m.remove m.first

set-test-last n:
  s := {}
  n.repeat: s.add (random 0 n)
  while s.size != 0:
    s.remove s.last

map-test-last n:
  m := {:}
  n.repeat:
    r := random 0 n
    m[r] = r
  while m.size != 0:
    m.remove m.last

// This tests a case that previously took quadratic time.  The index slots were
// not reused, so every time the entry was removed and re-added it would use a
// new slot in the index that could only be found by starting at the slot
// indicated by the hash and searching forwards past all the other unused
// slots.
set-test-index-clogged n:
  start := Time.now
  s := {}
  n.repeat: s.add (random 0 n)
  n.repeat:
    s.remove 0
    s.add 0
  end := Time.now
  print "$n: $(start.to end) $((start.to end).in-us / n)us per iterations"
