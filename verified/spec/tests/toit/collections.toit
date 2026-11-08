// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  list := [3, 1, 4, 1, 5, 9, 2, 6]
  print list
  print list.size
  list.add 5
  list.add-all [3, 5]
  print list
  list.sort --in-place
  print list
  print (list.map: it * 2)
  print (list.filter: it % 2 == 1)
  print (list.reduce: | a b | a + b)
  print list.first
  print list.last
  print (list.index-of 9)
  print (list.contains 7)
  print list[2..5]
  reversed := list.copy.sort: | a b | b - a
  print reversed

  array := Array_ 5 0
  5.repeat: array[it] = it * it
  print array

  // A list large enough to need a large array backing.
  big := List 1200: it
  sum := 0
  big.do: sum += it
  print sum
  print big[1199]
  big[1000] = -1
  print big[1000]

  bytes := ByteArray 8: it * 3
  print bytes
  bytes[0] = 255
  print bytes[0]
  print bytes[2..5]

  set := {}
  [5, 3, 5, 1, 3].do: set.add it
  print set
  print (set.contains 3)
  set.remove 3
  print set

  deque := Deque
  deque.add 1
  deque.add 2
  deque.add-first 0
  print deque
  print deque.remove-first
  print deque.size

  nested := [[1, 2], [3, [4, 5]], []]
  print nested
  print (nested.map: it.size)
