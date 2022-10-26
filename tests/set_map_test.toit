// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

test_map:
  n := 213
  map := Map
  for i := 0; i < n; i++:
    map[i.stringify] = i
    map[i] = i + i
  map["fjummer"] = 123
  for i := 0; i < n; i++:
    expect (map.contains i.stringify)
    expect (map.contains i)
  expect (map.contains "fjummer")
  map.remove "fjummer"
  expect (not map.contains "fjummer")
  map[#['f', 'j', 'u', 'm', 'm', 'e', 'r']] = 243
  for i := 0; i < n; i++:
    expect (map.contains i.stringify)
    expect (map.contains i)
  expect (map.contains #['f', 'j', 'u', 'm', 'm', 'e', 'r'])
  map.remove #['f', 'j', 'u', 'm', 'm', 'e', 'r']
  expect (not map.contains #['f', 'j', 'u', 'm', 'm', 'e', 'r'])
  for i := 0; i < n; i++:
    expect (map.contains i.stringify)
    expect (map.contains i)
  expect map.size == n * 2
  expect map[n - 1] == map[(n - 1).stringify] * 2
  for i := n - 1; i >= 0; i--:
    map.remove i.stringify
    map.remove i
  expect map.size == 0

  sum := 0
  {:}.do: | key value | sum += (value - key)
  {:}.do --reversed: | key value | sum += (value - key)
  expect_equals 0 sum

  sum = 0
  { 1: 2 }.do: | key value | sum += (value - key)
  expect_equals 1 sum
  { 1: 2 }.do --reversed: | key value | sum += (value - key)
  expect_equals 2 sum

  sum = 0
  { 1: 2, 2: 4 }.do: | key value | sum += (value - key)
  expect_equals (1 + 2) sum

  sum = 0
  { 1: 2, 2: 4 }.do --reversed: | key value | sum += (value - key)
  expect_equals (1 + 2) sum

  sum = 0
  { 1: 2, 1: 3 }.do: | key value | sum += (value - key)
  expect_equals 2 sum

  sum = 0
  { 1: 2, 1: 3 }.do --reversed: | key value | sum += (value - key)
  expect_equals 2 sum

  sum = 0
  { 1: 2, 2: 3 }.do --values: sum += it
  expect_equals (2 + 3) sum

  sum = 0
  { 1: 2, 2: 3 }.do --values --reversed: sum += it
  expect_equals (2 + 3) sum

  sum = 0
  { 1: 2, 2: 3 }.do --keys: sum += it
  expect_equals (1 + 2) sum

  sum = 0
  { 1: 2, 2: 3 }.do --keys --reversed: sum += it
  expect_equals (1 + 2) sum

  str := ""
  { 1: 2, 2: 3 }.do: | key value | str += "$key: $value "
  expect_equals "1: 2 2: 3 " str

  expect_equals ({ 1: 1, 2: 2}.filter: true).size 2
  expect_equals ({ 1: 1, 2: 2}.filter: false).size 0
  expect_equals ({ 1: 1, 2: 2}.filter: 1 == it)[1] 1

  map = { 1: 1, 2: 2 }
  map.filter --in_place: true
  expect_equals 2 map.size

  map.filter --in_place: false
  expect_equals 0 map.size

  map = { 1: 1, 2: 2 }
  map.filter --in_place: |key value| value == 1
  expect_equals 1 map.size

  map = { 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6,
          7: 7, 8: 8, 9: 9, 10: 10, 11: 11, 12: 12}
  map.filter --in_place: |key value| value > 11
  expect_equals 1 map.size
  expect_equals 12 map[12]

  map = { 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6,
          7: 7, 8: 8, 9: 9, 10: 10, 11: 11, 12: 12}
  map2 := map.map: |key value| value * 2
  expect_equals 12 map2.size
  expect_equals 24 map2[12]
  expect_equals 12 map[12]
  map2.map --in_place: |key value| value - 1
  expect_equals 12 map2.size
  expect_equals 23 map2[12]

  test_map_clear

test_map_clear:
  map := { 1: 1 }

  map.clear
  expect map.is_empty

  map.clear
  expect map.is_empty

  for i := 0; i < 100; i++:
    map[i] = i
  for i := 0; i < 100; i++:
    expect_equals i map[i]
  map.clear
  expect map.is_empty
  for i := 0; i < 100; i++:
    map[i] = i
  for i := 0; i < 100; i++:
    expect_equals i map[i]
  map.clear
  expect map.is_empty


test_set:
  test_set_basics
  test_set_equals
  test_set_union
  test_set_intersection
  test_set_difference
  test_contains_all
  test_set_filter
  test_set_map
  test_set_reduce
  test_set_clear

test_set_basics:
  n := 213
  set := Set
  for i := 0; i < n; i++:
    set.add i.stringify
    set.add i
  set.add "fjummer"
  set.do:
    expect
      set.contains it.stringify
    expect
      set.contains it
  set.do --reversed:
    expect
      set.contains it.stringify
    expect
      set.contains it
  expect (set.contains "fjummer")
  set.remove "fjummer"
  expect (not set.contains "fjummer")
  set.do:
    expect
      set.contains it.stringify
    expect
      set.contains it
  set.do --reversed:
    expect
      set.contains it.stringify
    expect
      set.contains it
  expect set.size == n * 2
  for i := n - 1; i >= 0; i--:
    set.remove i.stringify
    set.remove i
  expect set.size == 0

  sum := 0
  {}.do: sum += it
  expect_equals 0 sum

  {}.do --reversed: sum += it
  expect_equals 0 sum

  sum = 0
  {1, 2, 3}.do: sum += it
  expect_equals
    1 + 2 + 3
    sum

  sum = 0
  {1, 2, 3}.do --reversed: sum += it
  expect_equals
    1 + 2 + 3
    sum

  str := ""
  {1, 2, 3}.do: str += "$it "
  expect_equals
    "1 2 3 "
    str

  str = ""
  {1, 2, 3}.do --reversed: str += "$it "
  expect_equals
    "3 2 1 "
    str

  sum = 0
  {1, 2, 2}.do: sum += it
  expect_equals (1 + 2) sum

  sum = 0
  {1, 2, 2}.do --reversed: sum += it
  expect_equals (1 + 2) sum

test_set_equals:
  expect_equals {} {}
  expect_equals {1, 2} {1, 2}
  expect {1, 2} != {3, 4}

test_set_union:
  set := {1, 2}
  set.add_all set
  expect_equals {1, 2} set
  set.add_all {3, 4}
  expect_equals {1, 2, 3, 4} set

test_set_intersection:
  expect_equals {1, 2} ({1, 2}.intersect {1, 2})
  expect_equals {} ({1, 2}.intersect {3, 4})
  expect_equals {2} ({1, 2}.intersect {2, 3})


  set := {1, 2}
  other := {1, 2}
  set.intersect --in_place other
  expect_equals {1, 2} set

  set = {1, 2}
  other = {3, 4}
  set.intersect --in_place other
  expect_equals {} set

  set = {1, 2}
  other = {2, 3}
  set.intersect --in_place other
  expect_equals {2} set

test_set_difference:
  set := {1, 2}
  set.remove_all {1, 2}
  expect_equals {} set

  set = {1, 2}
  set.remove_all {2}
  expect_equals {1} set

  set = {1, 2}
  set.remove_all {3, 4}
  expect_equals {1, 2} set

test_contains_all:
  expect ({}.contains_all {})
  expect ({1, 2}.contains_all {1, 2})
  expect ({1, 2}.contains_all {2})
  expect ({1, 2}.contains_all {})
  expect (not {1, 2}.contains_all {2, 3})
  expect (not {1, 2}.contains_all {3, 4})

test_set_filter:
  expect_equals
    {1, 2}
    {1, 2}.filter: true
  expect_equals
    {}
    {1, 2}.filter: false
  expect_equals
    {1}
    {1, 2}.filter: 1 == it

  set := {1, 2}
  set.filter --in_place: true
  expect_equals {1, 2} set

  set.filter --in_place: false
  expect_equals {} set

  set = {1, 2}
  set.filter --in_place: 1 == it
  expect_equals {1} set

  set = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
  set.filter --in_place: it > 5
  expect_equals {6, 7, 8, 9, 10, 11, 12} set
  set.filter --in_place: it > 11
  expect_equals {12} set

test_set_map:
  expect_equals ({1, 2}.map: 2 * it) {2, 4}

test_set_reduce:
  expect_equals
    10
    {1, 2, 3, 4}.reduce: | sum e | sum + e

  expect_equals
    0
    {}.reduce --initial=0: 12
  expect_equals
    11
    {1, 2, 3, 4}.reduce --initial=1: | sum e | sum + e

test_set_clear:
  set := { 1, 2, 3 }
  set.clear
  expect set.is_empty

  set.clear
  expect set.is_empty

  for i := 0; i < 100; i++:
    set.add i
  for i := 0; i < 100; i++:
    expect (set.contains i)
  set.clear
  expect set.is_empty
  for i := 0; i < 100; i++:
    set.add i
  for i := 0; i < 100; i++:
    expect (set.contains i)
  set.clear
  expect set.is_empty

second set:
  first := true
  set.do:
    if first:
      first = false
    else:
      return it
  unreachable

penultimate set:
  last := true
  set.do --reversed:
    if last:
      last = false
    else:
      return it
  unreachable

test_remove:
  set := {}
  100.repeat: set.add it
  // Not enough to cause the set to be shrunk, but enough to generate skip
  // entries in the backing.
  20.repeat: set.remove it
  expect_equals 20 set.first
  // Leave 20 in there and remove enough after it to generate skip entries.
  20.repeat: set.remove it + 21
  expect_equals 20 set.first
  expect_equals 41 (second set)
  set.remove 20
  expect_equals 41 set.first
  expect_equals 42 (second set)
  set.do: it
  expect_equals 41 set.first
  expect_equals 42 (second set)
  set.do: it
  10.repeat:
    expect_equals 59 set.size
    expect_equals 99 set.last
    expect_equals 98 (penultimate set)
    if it % 2 == 0:
      20.repeat: set.remove 99 - it
    else:
      20.repeat: set.remove 80 + it
    expect_equals 79 set.last
    20.repeat: set.add 80 + it
    expect_equals 99 set.last
    expect_equals 98 (penultimate set)
  expect_equals 41 set.first
  expect_equals 42 (second set)

  map := {:}
  100.repeat: map[it] = it
  // Not enough to cause the map to be shrunk, but enough to generate skip
  // entries in the backing.
  20.repeat: map.remove it
  expect_equals 20 map.first
  // Leave 20 in there and remove enough after it to generate skip entries.
  20.repeat: map.remove it + 21
  expect_equals 20 map.first
  expect_equals 41 (second map)
  map.remove 20
  expect_equals 41 map.first
  expect_equals 42 (second map)
  map.do: it
  expect_equals 41 map.first
  expect_equals 42 (second map)
  map.do: it
  10.repeat:
    expect_equals 59 map.size
    expect_equals 99 map.last
    expect_equals 98 (penultimate map)
    if it % 2 == 0:
      20.repeat: map.remove 99 - it
    else:
      20.repeat: map.remove 80 + it
    expect_equals 79 map.last
    20.repeat: map[80 + it] = 80 + it
    expect_equals 99 map.last
    expect_equals 98 (penultimate map)
  expect_equals 41 map.first
  expect_equals 42 (second map)

// In terms of equality we only look at the string, but there is an
// extra field that enables us to distinguish instances from each other.
class Foo:
  hash_code_ := null
  unique := null
  string_ := null

  constructor .string_ .unique:

  hash_code -> int:
    return string_.hash_code

  operator == other -> bool:
    if other is not Foo: return false
    return other.string_ == string_

test_compatible_object:
  set := Set

  hello := Foo "Hello" 103
  set.add hello
  expect_equals 1 (set.size)

  world := Foo "World" 1
  // Do some tests before adding the new object to test the if_absent paths.
  expect_equals
    false
    set.contains world
  expect_equals
    null
    set.get world
  expect_equals
    "fish"
    set.get world --if_absent=:
      "fish"

  // Add the new object and verify it is there.
  set.add world
  expect_equals 2 (set.size)

  hello_2 := Foo "Hello" 42
  // This hello_2 is equal to the hello object, so this returns true.
  expect
    set.contains hello_2

  // This gets the hello object out of the set that matches the hello_2 object.
  hello_retrieved := set.get hello_2
  expect_equals 103 hello_retrieved.unique

  // Overwrite the hello object with the hello_2 object.
  set.add hello_2
  expect_equals 2 (set.size)

  // Check we get the right one back, using 'get'.
  hello_retrieved = set.get hello_2
  expect_equals 42 hello_retrieved.unique

  // Check we get the right one back, using 'get'.
  hello_retrieved = set.get hello
  expect_equals 42 hello_retrieved.unique

test_set_find set:
  baseline := set.size

  // Set does not contain "foo".
  ok := false
  result := set.get_by_hash_ 123
    --initial=:
      ok = true
      null  // Don't add anything to the set.
    --compare=: | x |
      expect x != "foo"
      false
  expect ok
  expect_equals null result

  // Add foo to the set using the hash code.
  h := "foo".hash_code
  ok = false
  result = set.get_by_hash_ h
    --initial=:
      ok = true
      "foo"      // Add foo to the set.
    --compare=: | x |
      expect x != "foo"  // It's not already there.
      false              // So the compare is always false.
  expect
    set.contains "foo"
  expect_equals "foo" result
  expect_equals baseline + 1 set.size

  // Check that "foo" is now present and findable using its hash code.
  ok = false
  result = set.get_by_hash_ h
    --initial=:
      throw "unreachable"
    --compare=: | x |
      if x == "foo":
        ok = true
      x == "foo"
  expect ok
  expect_equals "foo" result

  // Add "bar" in the conventional way.
  set.add "bar"
  expect_equals baseline + 2 set.size

  // We have an object that is not a string, that can be used to probe
  // whether a string is in the set.
  bar_probe := Stringlike 'b' 'a' 'r'
  ok = false
  result = set.get_by_hash_ bar_probe.hsh_cd
    --initial=:
      throw "unreachable"
    --compare=: | x |
      equality := bar_probe.matches x
      if equality:
        ok = true
      equality
  expect_equals baseline + 2 set.size
  expect_equals "bar" result
  expect ok

class Stringlike:
  letter1/int ::= ?
  letter2/int ::= ?
  letter3/int ::= ?
  hsh_cd/int ::= ?

  constructor .letter1 .letter2 .letter3:
    hsh_cd = #[letter1, letter2, letter3].to_string.hash_code

  matches x/string -> bool:
    if x.size != 3: return false
    if x[0] != letter1: return false
    if x[1] != letter2: return false
    if x[2] != letter3: return false
    return true

main:
  stats := process_stats
  initial_gcs := stats[STATS_INDEX_FULL_GC_COUNT]
  initial_compacts := stats[STATS_INDEX_FULL_COMPACTING_GC_COUNT]

  test_map
  test_set
  test_remove
  test_compatible_object
  test_set_find {}
  test_set_find {"one", "two", "three", "four", "five"}
  // 2650 has the same hash code as foo.
  test_set_find {"one", "two", "three", "four", "five", "2650"}

  stats = process_stats
  final_gcs := stats[STATS_INDEX_FULL_GC_COUNT]
  gcs := final_gcs - initial_gcs
  final_compacts := stats[STATS_INDEX_FULL_COMPACTING_GC_COUNT]
  print "Performed $(gcs) full GC$(gcs == 1 ? "" : "s"), $(final_compacts - initial_compacts) of them compacting"
  expect 0 <= initial_gcs <= final_gcs
