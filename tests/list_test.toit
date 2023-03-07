// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

comp a b:
  return (a < b) ? 1 : (a > b ? -1 : 0)

main:
  test_list
  test_sort --no-in_place
  test_sort --in_place
  test_index_of
  test_fill
  test_constructors
  test_slice
  test_replace
  test_replace_large

test_list:
  list := [13, 1, 13, 13, 2]
  list.add 13
  expect list.size == 6
  expect list[0] == 13
  expect list[1] == 1

  expect (list.any: it == 2)
  expect (list.every: it != 7)
  expect (list.contains 1)
  expect (list.contains 13)
  expect (not list.contains 7)

  // clear
  list.clear
  expect list.size == 0
  // add_all
  list.add_all [1, 2]
  expect_equals 2 list.size
  expect_equals 1 list[0]
  expect_equals 2 list[1]
  // equals
  expect list == [1, 2]
  expect list != [1, 2, 3]
  // remove_last
  expect list.remove_last == 2
  expect list.size == 1
  // remove_last
  expect list.remove_last == 1
  expect list.size == 0
  // remove
  list = [ 1, 2, 3, 4 ]
  list.remove 3
  expect_list_equals [ 1, 2, 4 ] list
  list = []
  list.remove 3
  expect_list_equals [] list
  list = [3]
  list.remove 3
  expect_list_equals [] list
  list = [5]
  list.remove 3
  expect_list_equals [5] list
  list = [1, 3, 5, 3, 7, 3]
  list.remove 3
  expect_list_equals [1, 5, 3, 7, 3] list

  // remove --all
  list = [ 1, 2, 3, 4 ]
  list.remove --all 3
  expect_list_equals [ 1, 2, 4 ] list
  list = []
  list.remove --all 3
  expect_list_equals [] list
  list = [3]
  list.remove --all 3
  expect_list_equals [] list
  list = [5]
  list.remove --all 3
  expect_list_equals [5] list
  list = [1, 3, 5, 3, 7, 3]
  list.remove --all 3
  expect_list_equals [1, 5, 7] list

  // remove --last
  list = [ 1, 2, 3, 4 ]
  list.remove --last 3
  expect_list_equals [ 1, 2, 4 ] list
  list = []
  list.remove --last 3
  expect_list_equals [] list
  list = [3]
  list.remove --last 3
  expect_list_equals [] list
  list = [5]
  list.remove --last 3
  expect_list_equals [5] list
  list = [1, 3, 5, 3, 7, 3]
  list.remove --last 3
  expect_list_equals [1, 3, 5, 3, 7] list
  list = [1, 3, 5, 3, 7, 3, 9]
  list.remove --last 3
  expect_list_equals [1, 3, 5, 3, 7, 9] list

check_in_place in_place/bool list sorted:
  if in_place:
    expect (identical list sorted)
  else:
    expect (not identical list sorted)
  return sorted

test_sort --in_place/bool:
  test_sort_basic --in_place=in_place
  test_sort_stability --in_place=in_place
  test_sort_partial --in_place=in_place
  test_sort_bad_compare_block --in_place=in_place

test_sort_basic --in_place/bool:
  // Sort using default compare.
  list := [11, 1, 14, 9, -1]
  expect (not list.is_sorted)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place
  expect list.is_sorted
  expect list == [-1, 1, 9, 11, 14]
  // Sort using customized compare (reverse order).
  list = [11, 1, 14, 9, -1]
  expect (not list.is_sorted: | a b | comp a b)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | comp a b
  expect
    list.is_sorted: | a b | comp a b
  expect list == [14, 11, 9, 1, -1]

  tmp := []
  [].do --reversed: tmp.add it
  expect tmp.is_empty
  list.do --reversed: tmp.add it
  expect_equals [-1, 1, 9, 11, 14] tmp

  // Big enough to trigger mergesort.
  long := []
  1200.repeat: long.add
    random 0 1200
  expect (not long.is_sorted) // Test random.
  long = check_in_place in_place
      long
      long.sort --in_place=in_place
  expect long.is_sorted

  // Presorted - avoid worst case.
  long = check_in_place in_place
      long
      long.sort --in_place=in_place
  expect long.is_sorted

  // Reverse sorted - avoid worst case.
  long = check_in_place in_place
      long
      long.sort --in_place=in_place: | a b | comp a b
  expect (not long.is_sorted) // Test random.
  expect (long.is_sorted: | a b | comp a b)

  100.repeat: | size |
    l := []
    size.repeat:
      l.add
        random 0 size
    if size > 20:
      expect (not l.is_sorted)
    l = check_in_place in_place
        l
        l.sort --in_place=in_place
    expect l.is_sorted
    l = check_in_place in_place
        l
        l.sort --in_place=in_place: | a b | comp a b
    if size > 20:
      expect (not l.is_sorted)
    expect (l.is_sorted: | a b | comp a b)

  // Test almost sorted lists.
  10.repeat:
    list = []
    100.repeat: list.add (random 0 100)
    list = check_in_place in_place
        list
        list.sort --in_place=in_place
    80.repeat:
      list.add (random 0 100)
      list.add (random 0 100)
      list.add (random 0 100)
      list.add (random 0 100)
      list.add (random 0 100)
      list[random 0 list.size] = random 0 100
      list = check_in_place in_place
          list
          list.sort --in_place=in_place
      (list.size - 1).repeat:
        expect list[it] <= list[it + 1]

test_sort_stability --in_place/bool:
  expect (Coordinate 0 0) == (Coordinate 0 0)
  expect (Coordinate 0 0) <  (Coordinate 0 1)
  expect (Coordinate 0 0) <  (Coordinate 1 0)
  expect (Coordinate 0 0) <  (Coordinate 1 1)
  expect (Coordinate 0 1) >  (Coordinate 0 0)
  expect (Coordinate 0 1) == (Coordinate 0 1)
  expect (Coordinate 0 1) <  (Coordinate 1 0)
  expect (Coordinate 0 1) <  (Coordinate 1 1)
  expect (Coordinate 1 0) >  (Coordinate 0 0)
  expect (Coordinate 1 0) >  (Coordinate 0 1)
  expect (Coordinate 1 0) == (Coordinate 1 0)
  expect (Coordinate 1 0) <  (Coordinate 1 1)
  expect (Coordinate 1 1) >  (Coordinate 0 0)
  expect (Coordinate 1 1) >  (Coordinate 0 1)
  expect (Coordinate 1 1) >  (Coordinate 1 0)
  expect (Coordinate 1 1) == (Coordinate 1 1)

  list := []
  list.add (Coordinate 1 2)
  list.add (Coordinate 3 4)
  list.add (Coordinate 1 4)
  list.add (Coordinate 2 4)
  list.add (Coordinate 2 2)
  list.add (Coordinate 2 4)

  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | (a.x - b.x).sign
  // Test the sort is stable.
  expect list[0] == (Coordinate 1 2)
  expect list[1] == (Coordinate 1 4)
  expect list[2] == (Coordinate 2 4)
  expect list[3] == (Coordinate 2 2)
  expect list[4] == (Coordinate 2 4)

  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | (a.y - b.y).sign
  // Test the sort is stable.
  expect list[0] == (Coordinate 1 2)
  expect list[1] == (Coordinate 2 2)
  expect list[2] == (Coordinate 1 4)
  expect list[3] == (Coordinate 2 4)
  expect list[4] == (Coordinate 2 4)

  expect (not list.is_sorted)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place
  expect list.is_sorted
  print list

  list = []
  150.repeat: list.add (Coordinate 0 it)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | (a.x - b.x).sign
  expect (list.is_sorted: | a b | (a.y - b.y).sign)

  list = []
  200.repeat: list.add (Coordinate (random 0 2) it)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | (a.x - b.x).sign
  zeros := list.filter: it.x == 0
  ones := list.filter: it.x == 1
  expect (zeros.is_sorted: | a b | (a.y - b.y).sign)
  expect (ones.is_sorted: | a b | (a.y - b.y).sign)

  list = []
  200.repeat: list.add (Coordinate (random 0 5) it)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: | a b | (a.x - b.x).sign
  5.repeat: | select |
    sublist := list.filter: it.x == select
    expect (sublist.is_sorted: | a b | (a.y - b.y).sign)

test_sort_partial --in_place/bool:
  list := List
  INITIAL ::= [1, 15, 2, 32, -1]
  list.add_all INITIAL
  (INITIAL.size + 1).repeat: | position |
    list = check_in_place in_place
        list
        list.sort --in_place=in_place position position  // Sort empty interval.
    i := 0
    INITIAL.do: expect list[i++] == it

  INITIAL.size.repeat: | position |
    list = check_in_place in_place
        list
        list.sort --in_place=in_place position position + 1  // Sort one element interval.
    i := 0
    INITIAL.do: expect list[i++] == it

  list = check_in_place in_place
      list
      list.sort --in_place=in_place 0 2
  i := 0
  INITIAL.do:
    if i > 1: expect list[i] == it
    i++

  list = check_in_place in_place
      list
      list.sort --in_place=in_place 1 4
  i = 0
  [1, 2, 15, 32, -1].do:
    expect list[i++] == it

  list = check_in_place in_place
      list
      list.sort --in_place=in_place 1 4: | a b | comp a b
  i = 0
  [1, 32, 15, 2, -1].do:
    expect list[i++] == it

  expect list.remove_last == -1

  list = check_in_place in_place
      list
      list.sort --in_place=in_place
  i = 0
  [1, 2, 15, 32].do: expect list[i++] == it

  expect_throws "OUT_OF_BOUNDS": list.sort --in_place=in_place -1 2
  expect_throws "OUT_OF_BOUNDS": list.sort --in_place=in_place 0 5
  expect_throws "OUT_OF_BOUNDS": list.sort --in_place=in_place 2 1

test_sort_bad_compare_block --in_place:
  // Expect it to terminate with stupid compare block.
  list := []
  100.repeat: list.add (random 0 100)
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: -1
  list = check_in_place in_place
      list
      list.sort --in_place=in_place: (random 0 3) - 1

test_fill:
  // Fill.
  list := List
  list.resize 5
  5.repeat: expect_null list[it]
  list.fill 499
  list.do: expect_equals 499 it
  list.fill --from=2 42
  5.repeat:
    if it < 2: expect_equals 499 list[it]
    else: expect_equals 42 list[it]
  list.fill --to=3 0
  5.repeat:
    if it < 3: expect_equals 0 list[it]
    else: expect_equals 42 list[it]
  list.fill --from=3 --to=4 99
  5.repeat:
    if it < 3: expect_equals 0 list[it]
    else if it == 3: expect_equals 99 list[it]
    else: expect_equals 42 list[it]

test_filled_list size:
  FILLER ::= 0xdead
  list := List size FILLER
  expect_equals size list.size
  size.repeat: expect_equals FILLER list[it]
  GROWING_STEPS ::= 15
  // Make sure that the list is correctly growable.
  GROWING_STEPS.repeat: list.add it
  expect_equals (GROWING_STEPS + size) list.size
  GROWING_STEPS.repeat: expect_equals it list[size + it]
  size.repeat:
    expect_equals FILLER list[it]

test_fill_block_list size:
  list := List size: it + 499
  expect_equals size list.size
  size.repeat: expect_equals (it + 499) list[it]
  GROWING_STEPS ::= 15
  // Make sure that the list is correctly growable.
  GROWING_STEPS.repeat: list.add it
  expect_equals (GROWING_STEPS + size) list.size
  GROWING_STEPS.repeat: expect_equals it list[size + it]
  size.repeat:
    expect_equals (it + 499) list[it]

test_index_of:
  list := [1, 2, 3, 4]
  expect_equals 0 (list.index_of 1)
  expect_equals 1 (list.index_of 2)
  expect_equals 2 (list.index_of 3)
  expect_equals 3 (list.index_of 4)
  expect_equals -1 (list.index_of 5)
  expect_equals 0 (list.index_of --last 1)
  expect_equals 1 (list.index_of --last 2)
  expect_equals 2 (list.index_of --last 3)
  expect_equals 3 (list.index_of --last 4)
  expect_equals -1 (list.index_of --last 5)
  expect_equals -1 (list.index_of 1 1)
  expect_equals -1 (list.index_of --last 1 1)
  expect_equals 0 (list.index_of 1 0 1)
  expect_equals 0 (list.index_of --last 1 0 1)
  expect_equals -1 (list.index_of 1 1 2)
  expect_equals -1 (list.index_of --last 1 1 2)
  expect_equals -1 (list.index_of 1 0 0)
  expect_equals -1 (list.index_of --last 1 1 1)
  expect_throws "BAD ARGUMENTS": list.index_of 2 -11 99
  expect_throws "BAD ARGUMENTS": list.index_of 2 5 5

  expect_equals 499 (list.index_of 5 --if_absent=:499)

  expect_equals 0 (list.index_of --binary 1)
  expect_equals 1 (list.index_of --binary 2)
  expect_equals 2 (list.index_of --binary 3)
  expect_equals 3 (list.index_of --binary 4)
  expect_equals -1 (list.index_of --binary 0)
  expect_equals -1 (list.index_of --binary 5)

  expect_equals 499 (list.index_of --binary 5 --if_absent=:499)

  list = [4, 3, 2, 1]
  comp := : | a b |
    if a < b: 1
    else if a == b: 0
    else: -1
  expect_equals 3 (list.index_of --binary_compare=comp 1)
  expect_equals 2 (list.index_of --binary_compare=comp 2)
  expect_equals 1 (list.index_of --binary_compare=comp 3)
  expect_equals 0 (list.index_of --binary_compare=comp 4)
  expect_equals -1 (list.index_of --binary_compare=comp 0)
  expect_equals -1 (list.index_of --binary_compare=comp 5)

  expect_equals 499 (list.index_of --binary_compare=comp 5 --if_absent=:499)

  expect_equals -1 ([].index_of --binary 5)
  expect_equals 0 ([5].index_of --binary 5)
  expect_equals -1 ([0].index_of --binary 5)
  expect_equals -1 ([9].index_of --binary 5)

  index := [0, 0, 0, 0].index_of --binary 0
  expect 0 <= index < 4

  location := 0
  [].index_of 5 --binary --if_absent=(: location = it)
  expect_equals 0 location

  location = 0
  [1].index_of 5 --binary --if_absent=(: location = it)
  expect_equals 1 location

  location = 0
  [9].index_of 5 --binary --if_absent=(: location = it)
  expect_equals 0 location

  location = 0
  [1, 3].index_of 2 --binary --if_absent=(: location = it)
  expect_equals 1 location

  location = 0
  [1, 3].index_of 5 --binary --if_absent=(: location = it)
  expect_equals 2 location

  location = 0
  [1, 3, 5].index_of 4 --binary --if_absent=(: location = it)
  expect_equals 2 location

  location = 0
  [1234, -1].index_of 5 1 1 --binary --if_absent=(: location = it)
  expect_equals 1 location

  location = 0
  [1234, 1, -1].index_of 5 1 2 --binary --if_absent=(: location = it)
  expect_equals 2 location

  location = 0
  [1234, 9, -1].index_of 5 1 2 --binary --if_absent=(: location = it)
  expect_equals 1 location

  location = 0
  [1234, 1, 3, -1].index_of 2 1 3 --binary --if_absent=(: location = it)
  expect_equals 2 location

  location = 0
  [1234, 1, 3, -1].index_of 5 1 3 --binary --if_absent=(: location = it)
  expect_equals 3 location

  location = 0
  [1234, 1, 3, 5, -1].index_of 4 1 4 --binary --if_absent=(: location = it)
  expect_equals 3 location

test_collection_list size:
  set := {}
  size.repeat: set.add (it + 499)
  list := List.from set
  size.repeat: expect_equals (it + 499) list[it]
  GROWING_STEPS ::= 15
  // Make sure that the list is correctly growable.
  GROWING_STEPS.repeat: list.add it
  expect_equals (GROWING_STEPS + size) list.size
  GROWING_STEPS.repeat: expect_equals it list[size + it]
  size.repeat:
    expect_equals (it + 499) list[it]

  list2 := List.from list
  expect_list_equals list list2

test_constructors:
  INTERESTING_SIZES ::= [0, 1, 9, 3000]

  INTERESTING_SIZES.do:
    test_filled_list it
    test_fill_block_list it
    test_collection_list it

test_slice:
  for i := 0; i < 2; i++:
    list := [1, 2, 3, 4, 5, 6]
    // In the second run, the 'list' is a slice itself.
    if i == 1: list = list[..]

    slice := list[..]
    expect_list_equals slice list
    // Test that the slice is just a view and modifies the underlying list.
    list[3] = 44
    expect_equals 44 slice[3]
    slice[3] = 4
    expect_equals 4 slice[3]
    expect_equals 4 list[3]
    expect list == slice

    slice = list[1..]
    expect_equals 5 slice.size
    slice[0] = 22
    expect_equals 22 list[1]
    list[1] = 2
    expect_equals 2 slice[0]

    slice = list[..4]
    expect_equals 4 slice.size
    expect_equals 1 slice[0]
    slice[0] = -1
    expect_equals -1 list[0]
    list[0] = 1
    expect_equals 1 slice[0]

    slice = list[..]
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.clear
    slice = list[1..]
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.clear
    slice = list[0..0]
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.clear

    slice = list[..]
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.add 5
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.add_all [5]

    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.remove 3
    // List.remove on a non-resizable list is an error and can
    // leave the list in an inconsistent state.
    list.size.repeat: list[it] = it + 1
    expect_throws "SLICE_CANNOT_CHANGE_SIZE": slice.remove --all 3
    // List.remove on a non-resizable list is an error and can
    // leave the list in an inconsistent state.
    list.size.repeat: list[it] = it + 1

    slice.remove 499 // OK, since 499 is not in the slice.

    list[0] = 499
    sorted := slice.sort  // Returns a copy
    expect_list_equals [2, 3, 4, 5, 6, 499] sorted
    expect_equals 499 list[0]
    expect_equals 499 slice[0]

    sorted = slice.sort --in_place
    expect_list_equals [2, 3, 4, 5, 6, 499] sorted
    expect_equals 2 list[0]
    expect_equals 2 slice[0]

    list[5] = 1
    slice = list[3..]
    slice.sort --in_place
    expect_list_equals [1, 5, 6] slice
    expect_list_equals [2, 3, 4, 1, 5, 6] list

    slice = list[..4]
    slice.sort --in_place
    expect_list_equals [1, 2, 3, 4] slice
    expect_list_equals [1, 2, 3, 4, 5, 6] list

    slice = list[2..4]
    slice.fill 499
    expect_list_equals [499, 499] slice
    expect_list_equals [1, 2, 499, 499, 5, 6] list
    slice.fill 33 --from=1
    expect_list_equals [499, 33] slice
    expect_list_equals [1, 2, 499, 33, 5, 6] list

test_replace:
  list := [1, 2, 3, 4, 5]
  copy := list.copy
  other := [11, 22, 33, 44, 55]

  list.replace 0 other
  expect_list_equals other list

  list.replace 0 copy
  expect_list_equals copy list

  list.replace 1 other[1..]
  expect_list_equals other[1..] list[1..]
  expect_equals 1 list[0]

  list.replace 0 copy
  expect_list_equals copy list

  list.replace 1 other[2..3]
  expect_equals 33 list[1]
  list[1] = 2
  expect_list_equals copy list

  list.replace 1 other 2 3
  expect_equals 33 list[1]
  list[1] = 2
  expect_list_equals copy list

  expect_throws "OUT_OF_BOUNDS": list.replace 1 other

  sublist := list[1..4]
  expect_throws "OUT_OF_BOUNDS": sublist.replace 0 [0, 0, 0, 0]

test_replace_large:
  // Some tests of the tricky code to do replace when the source and
  // destination are the same LargeArray.
  large := List 2500: it

  INDEX_FROM_TO ::= [
      [491, 490, 510],
      [491, 490, 1510],
      [500, 490, 1510],
      [490, 500, 1510],
      [491, 490, 1500],
      [500, 490, 1500],
      [490, 500, 1500],
      [491, 490, 2000],
      [500, 490, 2000],
      [490, 500, 2000],
  ]
  [490, 491, 500, 501, 510, 990, 1000, 1010].do: | index |
    [490, 491, 500, 501, 510, 990, 1000, 1010].do: | from |
      [from, from + 1, from + 10, from + 20, 1490, 1499, 1500, 1501, 1510].do: | to |
        large.size.repeat: large[it] = it
        large.replace index large from to

        large.size.repeat:
          if it < index:
            expect_equals it large[it]
          else if it < index + to - from:
            expect_equals (it + from - index) large[it]
          else:
            expect_equals it large[it]

class Coordinate implements Comparable:
  x := 0
  y := 0

  constructor .x/int .y/int:

  stringify: return "($x,$y)"

  compare_to other/Coordinate:
    if x == other.x: return (y - other.y).sign
    return (x - other.x).sign

  compare_to other/Coordinate [--if_equal]:
    unreachable

  operator < other/Coordinate -> bool: return (compare_to other) == -1
  operator <= other/Coordinate -> bool: return (compare_to other) != 1
  operator > other/Coordinate -> bool: return (compare_to other) == 1
  operator >= other/Coordinate -> bool: return (compare_to other) != -1
  operator == other/Coordinate -> bool: return other.x == x and other.y == y

expect_throws name [code]:
  expect_equals
    name
    catch code
