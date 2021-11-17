// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

main:
  array := List 15: random -it it
  print "Bubble sort"
  print "  before: $array"
  bubble_sort array
  print "  after:  $array"

bubble_sort a:
  size := a.size
  for i := 0; i < size; i++:
    limit := size - i - 1
    for j := 0; j < limit; j++:
      if a[j] > a[j + 1]: a.swap j j+1
  assert: a.is_sorted
