// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  simple
  check_gc_is_caused

simple -> none:
  x := 2.2342342
  print_objects

// We can't see the result, so we have to check visually the output of this
// test.  The second histogram should not have any more objects than the first.
check_gc_is_caused -> none:
  cause_floating_garbage
  print_objects

cause_floating_garbage:
  10.repeat:
    a := []
    1000.repeat:
      a.add "entry $it"
