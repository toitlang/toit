// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-deque
  test-at Deque
  test-at List
  test-copy
  test-reserve
  test-add-first-with-reserve

test-deque:
  deque := Deque
  deque.add-all [13, 1, 13, 13, 2]
  deque.add 13
  expect deque.size == 6

  expect (deque.any: it == 2)
  expect (deque.every: it != 7)
  expect (deque.contains 1)
  expect (deque.contains 13)
  expect (not deque.contains 7)

  expect-equals 13 deque.first
  expect-equals 13 deque.remove-first
  expect deque.size == 5

  deque.add-first 55
  expect-equals 55 deque.first
  deque.add-first 103
  expect-equals 103 deque.first
  expect-equals 103 deque.remove-first
  expect-equals 55 deque.remove-first

  expect-equals 1 deque.first
  expect-equals 1 deque.remove-first
  expect deque.size == 4

  expect (not deque.contains 1)

  expect-equals 13 * 13 * 13 * 2
    deque.reduce: | a b | a * b

  expect-equals 13 + 13 + 13 + 2
    deque.reduce: | a b | a + b

  expect-equals 0
    deque.reduce --initial=0: | a b | a * b

  // clear.
  deque.clear
  expect-equals 0 deque.size
  // add_all.
  deque.add-all [1, 2]
  expect-equals 2 deque.size
  // remove_last.
  expect-equals 2 deque.last
  expect-equals 2 deque.remove-last
  expect-equals 1 deque.size
  // remove_last.
  expect-equals 1 deque.last
  expect-equals 1 deque.remove-last
  expect-equals 0 deque.size

  deque.add 42
  deque.add 103

  // Keep removing first.
  100_000.repeat:
    deque.add it
    removed := deque.remove-first
    if it > 1:
      expect-equals it - 2 removed

  expect-equals 99_998 deque.first
  expect-equals 99_999 deque.last

  first := true

  deque.do:
    if first:
      expect it == 99_998
      first = false
    else:
      expect it == 99_999

  first = true

  deque.do --reversed:
    if first:
      expect it == 99_999
      first = false
    else:
      expect it == 99_998

test-at list:
  expect-equals 0 list.size
  expect-equals "[]" list.stringify
  expect-throw "OUT_OF_BOUNDS": list[0]
  expect-throw "OUT_OF_BOUNDS": list.remove-last
  expect-throw "OUT_OF_BOUNDS": list.remove --at=0
  expect-throw "OUT_OF_BOUNDS": list.remove --at=-1
  expect-throw "OUT_OF_BOUNDS": list.remove --at=1
  expect-throw "OUT_OF_BOUNDS": list.insert --at=-1 "foo"
  expect-throw "OUT_OF_BOUNDS": list.insert --at=1 "foo"
  list.insert --at=0 "foo"
  expect-equals 1 list.size
  expect-equals "[foo]" list.stringify
  expect-throw "OUT_OF_BOUNDS": list.remove --at=-1
  expect-throw "OUT_OF_BOUNDS": list.remove --at=1
  expect-throw "OUT_OF_BOUNDS": list.insert --at=-1 "bar"
  expect-throw "OUT_OF_BOUNDS": list.insert --at=2 "bar"
  expect-equals "foo" (list.remove --at=0)
  expect-equals 0 list.size
  expect-equals "[]" list.stringify
  list.insert --at=0 "foo"
  list.insert --at=0 "bar"
  expect-equals "[bar, foo]" list.stringify
  list.insert --at=2 "baz"
  expect-equals 3 list.size
  expect-equals "[bar, foo, baz]" list.stringify
  expect-equals "foo" (list.remove --at=1)
  expect-equals "[bar, baz]" list.stringify
  expect-equals "bar" (list.remove --at=0)
  expect-equals "[baz]" list.stringify
  expect-equals 1 list.size
  expect-equals "baz" (list.remove --at=0)

  10.repeat: list.add it
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  expect-equals 7 (list.remove --at=7)
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 1 (list.remove --at=1)
  expect-equals "[0, 2, 3, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 3 (list.remove --at=2)
  expect-equals "[0, 2, 4, 5, 6, 8, 9]" list.stringify
  expect-equals 6 (list.remove --at=4)
  expect-equals "[0, 2, 4, 5, 8, 9]" list.stringify
  expect-equals 2 (list.remove --at=1)
  expect-equals "[0, 4, 5, 8, 9]" list.stringify
  expect-equals 8 (list.remove --at=3)
  expect-equals "[0, 4, 5, 9]" list.stringify
  expect-equals 4 (list.remove --at=1)
  expect-equals "[0, 5, 9]" list.stringify
  expect-equals 5 (list.remove --at=1)
  expect-equals "[0, 9]" list.stringify
  expect-equals 9 (list.remove --at=1)
  expect-equals "[0]" list.stringify
  expect-equals 0 (list.remove --at=0)
  expect-equals "[]" list.stringify

  10.repeat: list.insert --at=list.size it
  expect-equals 10 list.size
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  list.insert --at=1 42
  expect-equals 11 list.size
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  list.insert --at=9 103
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 7, 103, 8, 9]" list.stringify
  list.insert --at=8 102
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 9]" list.stringify
  list.insert --at=(list.size - 1) 99
  expect-equals "[0, 42, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 99, 9]" list.stringify
  list.insert --at=2 -1
  expect-equals "[0, 42, -1, 1, 2, 3, 4, 5, 6, 102, 7, 103, 8, 99, 9]" list.stringify

  expect-equals 0 (list.index-of 0)
  expect-equals 1 (list.index-of 42)
  list.clear
  expect-equals 0 list.size
  10.repeat: list.add it
  expect-equals "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  expect-equals 5 (list.index-of --binary 5)
  r := list.index-of --binary 10 --if-absent=:
    expect-equals 10 it
    42
  expect-equals 42 r
  r = list.index-of --binary -1 --if-absent=:
    expect-equals 0 it
    42
  expect-equals 42 r
  expect-equals 0 (list.remove --at=0)
  expect-equals 1 (list.remove --at=0)
  r = list.index-of --binary 10 --if-absent=:
    expect-equals 8 it
    42
  expect-equals 42 r
  expect-equals "[2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  r = list.index-of --binary 8 0 5 --if-absent=:
    expect-equals 5 it
    42
  expect-equals 42 r
  expect-equals "[2, 3, 4, 5, 6, 7, 8, 9]" list.stringify
  r = list.index-of --binary 8 0 6 --if-absent=:
    expect-equals 6 it
    42
  expect-equals 42 r
  expect-equals 6 (list.index-of --binary 8 0 7)
  expect-equals 42 r

test-copy:
  d := Deque
  d.add-all [1, 2, 3]
  d2/Deque := d.copy
  d[1] = 42
  d2[1] = 103
  expect-equals "[1, 42, 3]" d.stringify
  expect-equals "[1, 103, 3]" d2.stringify
  d.remove-last
  d2.remove-first
  expect-equals "[1, 42]" d.stringify
  expect-equals "[103, 3]" d2.stringify

test-reserve:
  // Basic reserve on empty deque.
  d := Deque
  d.reserve 10
  expect d.backing_.size >= 10
  expect-equals 0 d.size
  d.add-all [1, 2, 3]
  expect-equals 3 d.size
  expect-equals "[1, 2, 3]" d.stringify

  // Reserve on non-empty deque.
  d2 := Deque
  d2.add-all [1, 2, 3]
  expect-equals 3 d2.size
  d2.reserve 5
  expect d2.backing_.size >= 8
  expect-equals 3 d2.size
  expect-equals "[1, 2, 3]" d2.stringify

  // Adding elements after reserve should not reallocate.
  backing-before := d2.backing_
  d2.add 4
  d2.add 5
  d2.add 6
  d2.add 7
  d2.add 8
  expect-identical backing-before d2.backing_  // Should not have reallocated.
  expect-equals "[1, 2, 3, 4, 5, 6, 7, 8]" d2.stringify
  expect-equals 8 d2.size

  // Reserve when there's already reserved space.
  d3 := Deque
  d3.add-all [1, 2]
  d3.reserve 10
  first-backing-size := d3.backing_.size
  d3.reserve 5  // Already have more than 5 reserved.
  expect-equals first-backing-size d3.backing_.size  // Should not resize.
  expect-equals 2 d3.size

  // Reserve with exact amount needed.
  d4 := Deque
  d4.add-all [1, 2, 3]
  expect-equals 3 d4.backing_.size
  d4.reserve 2
  expect-equals 5 d4.backing_.size
  d4.add 4
  d4.add 5
  expect-equals 5 d4.size
  expect-equals "[1, 2, 3, 4, 5]" d4.stringify

  // Reserve zero should not change backing.
  d5 := Deque
  d5.add-all [1, 2]
  old-backing-size := d5.backing_.size
  d5.reserve 0
  expect-equals old-backing-size d5.backing_.size
  expect-equals 2 d5.size

  // Reserve after remove operations (tests last_ field).
  d6 := Deque
  d6.add-all [1, 2, 3, 4, 5]
  d6.remove-first
  d6.remove-first
  expect-equals 3 d6.size
  expect-equals 2 d6.start_
  d6.reserve 10
  // Reserve should calculate from last_, not from size.
  expect d6.backing_.size >= 15
  expect-equals 3 d6.size
  expect-equals 2 d6.start_

  // Adding at back after reserve uses reserved space.
  d7 := Deque
  d7.add-all [1, 2]
  d7.reserve 10
  backing-ref7 := d7.backing_
  d7.add 3
  d7.add 4
  expect-identical backing-ref7 d7.backing_  // Should not reallocate.
  expect-equals "[1, 2, 3, 4]" d7.stringify
  expect-equals 4 d7.size

  // Reserve on empty deque then add elements.
  d8 := Deque
  d8.reserve 20
  expect-equals 0 d8.size
  backing-ref8 := d8.backing_
  d8.add 1
  d8.add 2
  d8.add 3
  expect-identical backing-ref8 d8.backing_
  expect-equals "[1, 2, 3]" d8.stringify

  // Reserve with start_ != 0.
  d9 := Deque
  10.repeat: d9.add it
  5.repeat: d9.remove-first
  expect d9.start_ > 0
  old-first := d9.start_
  d9.reserve 15
  expect-equals old-first d9.start_  // start_ should not change.
  expect-equals "[5, 6, 7, 8, 9]" d9.stringify

  // Large reserve.
  d10 := Deque
  d10.add-all [1, 2, 3]
  d10.reserve 1000
  expect d10.backing_.size >= 1003
  expect-equals 3 d10.size
  expect-equals "[1, 2, 3]" d10.stringify
  backing-ref10 := d10.backing_
  100.repeat: d10.add (it + 4)
  expect-identical backing-ref10 d10.backing_  // No reallocation.
  expect-equals 103 d10.size

  // Reserve and remove-last interaction.
  d11 := Deque
  d11.add-all [1, 2, 3]
  d11.reserve 10
  old-backing11 := d11.backing_
  d11.remove-last
  expect-identical old-backing11 d11.backing_  // Should not shrink.
  expect-equals 2 d11.size
  expect-equals "[1, 2]" d11.stringify

  // Negative reserve should throw.
  d12 := Deque
  expect-throw "OUT_OF_BOUNDS": d12.reserve -1
  expect-throw "OUT_OF_BOUNDS": d12.reserve -100

  // Reserve then add-all.
  d13 := Deque
  d13.reserve 100
  old-backing-size = d13.backing_.size
  backing-ref13 := d13.backing_
  d13.add-all [1, 2, 3, 4, 5]
  expect-equals old-backing-size d13.backing_.size  // Should not reallocate.
  expect-identical backing-ref13 d13.backing_
  expect-equals 5 d13.size

  // Multiple reserves.
  d14 := Deque
  d14.reserve 10
  size1 := d14.backing_.size
  d14.reserve 20
  size2 := d14.backing_.size
  expect size2 > size1
  d14.reserve 5  // Less than already reserved.
  expect-equals size2 d14.backing_.size  // No change.

  // Reserve with deque at capacity.
  d15 := Deque
  d15.add-all [1, 2, 3]
  // At capacity when last_ == backing_.size
  d15.reserve 5
  expect d15.backing_.size >= 8
  backing-ref15 := d15.backing_
  d15.add 4
  expect-identical backing-ref15 d15.backing_  // Should use reserved space.
  expect-equals "[1, 2, 3, 4]" d15.stringify

  // Reserve corner case - after shrinking.
  d16 := Deque
  20.repeat: d16.add it
  15.repeat: d16.remove-first  // Trigger shrinking.
  expect-equals 5 d16.size
  // After shrinking, start_ should be 0 if shrink happened.
  d16.reserve 30
  backing-ref16 := d16.backing_
  25.repeat: d16.add (100 + it)
  expect-identical backing-ref16 d16.backing_  // No reallocation.
  expect-equals 30 d16.size

  // Reserve and last element access.
  d17 := Deque
  d17.add-all [1, 2, 3]
  d17.reserve 10
  expect-equals 3 d17.last
  d17.add 4
  expect-equals 4 d17.last
  d17.remove-last
  expect-equals 3 d17.last

  // Reserve preserves all elements.
  d18 := Deque
  100.repeat: d18.add it
  50.repeat: d18.remove-first
  d18.reserve 200
  expect-equals 50 d18.size
  // Verify all elements are preserved.
  50.repeat: expect-equals (50 + it) d18[it]

  // Reserve after remove-last when there's reserved space.
  d19 := Deque
  d19.add-all [1, 2, 3, 4, 5]
  d19.reserve 10
  expect d19.backing_.size >= 15
  d19.remove-last
  d19.remove-last
  backing-ref19 := d19.backing_
  d19.reserve 3  // Still have reserved space.
  expect-identical backing-ref19 d19.backing_
  expect-equals "[1, 2, 3]" d19.stringify

  // Reserve exact boundary.
  d20 := Deque
  d20.add-all [1, 2, 3]
  available := d20.backing_.size - 3
  d20.reserve available  // Exactly what's available.
  expect-equals 3 d20.backing_.size  // Should not resize.

  // Reserve one more than available.
  d21 := Deque
  d21.add-all [1, 2, 3]
  expect-equals 3 d21.backing_.size
  d21.reserve 1
  expect-equals 4 d21.backing_.size  // Should resize.

  // Multiple reserves with adds in between.
  d22 := Deque
  d22.reserve 5
  d22.add 1
  d22.add 2
  old-backing-size = d22.backing_.size
  d22.reserve 10  // Reserve more.
  expect d22.backing_.size >= 12
  expect-equals "[1, 2]" d22.stringify

  // Reserve and verify backing efficiency.
  d23 := Deque
  d23.reserve 50
  backing-ref23 := d23.backing_
  // Add many elements without reallocation.
  50.repeat: d23.add it
  expect-identical backing-ref23 d23.backing_
  expect-equals 50 d23.size

  // Reserve after clear.
  d24 := Deque
  10.repeat: d24.add it
  d24.clear
  expect-equals 0 d24.size
  d24.reserve 20
  backing-ref24 := d24.backing_
  15.repeat: d24.add it
  expect-identical backing-ref24 d24.backing_
  expect-equals 15 d24.size


test-add-first-with-reserve:
  // add-first after reserve on empty deque.
  d1 := Deque
  d1.reserve 10
  d1.add-first 1
  expect-equals "[1]" d1.stringify
  expect-equals 1 d1.size
  d1.add-first 2
  expect-equals "[2, 1]" d1.stringify
  expect-equals 2 d1.size

  // add-first after reserve on non-empty deque.
  d2 := Deque
  d2.add-all [1, 2, 3]
  d2.reserve 10
  backing-ref := d2.backing_
  d2.add-first 0
  expect-equals "[0, 1, 2, 3]" d2.stringify
  expect-equals 4 d2.size
  // Should have reallocated because start_ was 0.

  // add-first after reserve and remove-first.
  d3 := Deque
  d3.add-all [1, 2, 3, 4, 5]
  d3.reserve 10
  d3.remove-first
  d3.remove-first
  expect-equals "[3, 4, 5]" d3.stringify
  backing-ref = d3.backing_
  d3.add-first 2
  expect-identical backing-ref d3.backing_  // Should not reallocate.
  expect-equals "[2, 3, 4, 5]" d3.stringify
  d3.add-first 1
  expect-identical backing-ref d3.backing_  // Should not reallocate.
  expect-equals "[1, 2, 3, 4, 5]" d3.stringify

  // Alternating add-first and add after reserve.
  d4 := Deque
  d4.reserve 20
  d4.add 1
  d4.add-first 0
  d4.add 2
  d4.add-first -1
  expect-equals "[-1, 0, 1, 2]" d4.stringify
  expect-equals 4 d4.size

  // add-first multiple times with reserved space.
  d5 := Deque
  d5.add-all [5, 6, 7]
  d5.reserve 10
  // When add-first is called with start_ == 0, it creates new backing with padding.
  d5.add-first 4
  d5.add-first 3
  d5.add-first 2
  d5.add-first 1
  expect-equals "[1, 2, 3, 4, 5, 6, 7]" d5.stringify
  expect-equals 7 d5.size

  // add-first when start_ == 0 with reserved space at end.
  d6 := Deque
  d6.add-all [1, 2, 3]
  d6.reserve 10  // Reserved space at end.
  expect-equals 0 d6.start_
  d6.add-first 0
  // Should create new backing with padding at both ends.
  // Note: The new backing might be smaller than the reserved size.
  expect-equals "[0, 1, 2, 3]" d6.stringify
  expect-equals 4 d6.size
  expect d6.start_ > 0  // Should have some padding at the front now.

  // add-first preserves reserved space.
  d7 := Deque
  d7.add-all [2, 3, 4]
  d7.reserve 20
  reserved-before := d7.backing_.size - 3
  d7.add-first 1
  // After add-first (which reallocates), we should still have some reserved space.
  reserved-after := d7.backing_.size - 4
  expect reserved-after > 0
  expect-equals "[1, 2, 3, 4]" d7.stringify

  // add-first after reserve with mixed operations.
  d8 := Deque
  d8.reserve 50
  10.repeat: d8.add it
  backing-ref = d8.backing_
  d8.add-first -1
  // Should have created new backing.
  10.repeat:
    d8.add-first (-2 - it)
  expect-equals 21 d8.size
  expect-equals -11 d8.first
  expect-equals 9 d8.last

  // add-first works correctly with reserved space.
  d9 := Deque
  d9.add 1
  d9.add 2
  d9.reserve 5
  // This was the bug: add-first would try to copy entire backing_ instead of just [start_..last_].
  d9.add-first 0
  expect-equals "[0, 1, 2]" d9.stringify
  expect-equals 3 d9.size
  expect-equals 0 d9[0]
  expect-equals 1 d9[1]
  expect-equals 2 d9[2]


  // Large-scale add-first after reserve.
  d10 := Deque
  50.repeat: d10.add it
  d10.reserve 100
  // add-first will reallocate when start_ == 0.
  d10.add-first -1
  // Verify correctness.
  expect-equals 51 d10.size
  expect-equals -1 d10.first
  expect-equals 49 d10.last
  // Continue adding more elements.
  49.repeat: d10.add-first (-2 - it)
  expect-equals 100 d10.size
  expect-equals -50 d10.first
