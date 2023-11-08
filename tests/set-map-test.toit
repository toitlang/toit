// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import system show process-stats

test-map:
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
  expect-equals 0 sum

  sum = 0
  { 1: 2 }.do: | key value | sum += (value - key)
  expect-equals 1 sum
  { 1: 2 }.do --reversed: | key value | sum += (value - key)
  expect-equals 2 sum

  sum = 0
  { 1: 2, 2: 4 }.do: | key value | sum += (value - key)
  expect-equals (1 + 2) sum

  sum = 0
  { 1: 2, 2: 4 }.do --reversed: | key value | sum += (value - key)
  expect-equals (1 + 2) sum

  sum = 0
  { 1: 2, 1: 3 }.do: | key value | sum += (value - key)
  expect-equals 2 sum

  sum = 0
  { 1: 2, 1: 3 }.do --reversed: | key value | sum += (value - key)
  expect-equals 2 sum

  sum = 0
  { 1: 2, 2: 3 }.do --values: sum += it
  expect-equals (2 + 3) sum

  sum = 0
  { 1: 2, 2: 3 }.do --values --reversed: sum += it
  expect-equals (2 + 3) sum

  sum = 0
  { 1: 2, 2: 3 }.do --keys: sum += it
  expect-equals (1 + 2) sum

  sum = 0
  { 1: 2, 2: 3 }.do --keys --reversed: sum += it
  expect-equals (1 + 2) sum

  str := ""
  { 1: 2, 2: 3 }.do: | key value | str += "$key: $value "
  expect-equals "1: 2 2: 3 " str

  expect-equals ({ 1: 1, 2: 2}.filter: true).size 2
  expect-equals ({ 1: 1, 2: 2}.filter: false).size 0
  expect-equals ({ 1: 1, 2: 2}.filter: 1 == it)[1] 1

  map = { 1: 1, 2: 2 }
  map.filter --in-place: true
  expect-equals 2 map.size

  map.filter --in-place: false
  expect-equals 0 map.size

  map = { 1: 1, 2: 2 }
  map.filter --in-place: |key value| value == 1
  expect-equals 1 map.size

  map = { 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6,
          7: 7, 8: 8, 9: 9, 10: 10, 11: 11, 12: 12}
  map.filter --in-place: |key value| value > 11
  expect-equals 1 map.size
  expect-equals 12 map[12]

  map = { 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6,
          7: 7, 8: 8, 9: 9, 10: 10, 11: 11, 12: 12}
  map2 := map.map: |key value| value * 2
  expect-equals 12 map2.size
  expect-equals 24 map2[12]
  expect-equals 12 map[12]
  map2.map --in-place: |key value| value - 1
  expect-equals 12 map2.size
  expect-equals 23 map2[12]

  expect-throw "key '99' not found": map[99]
  expect-throw "key 'foo' not found": map["foo"]
  expect-throw "key not found": map[Foo "foo" true]

  test-map-clear

test-map-clear:
  map := { 1: 1 }

  map.clear
  expect map.is-empty

  map.clear
  expect map.is-empty

  for i := 0; i < 100; i++:
    map[i] = i
  for i := 0; i < 100; i++:
    expect-equals i map[i]
  map.clear
  expect map.is-empty
  for i := 0; i < 100; i++:
    map[i] = i
  for i := 0; i < 100; i++:
    expect-equals i map[i]
  map.clear
  expect map.is-empty


test-set:
  test-set-basics
  test-set-equals
  test-set-union
  test-set-intersection
  test-set-difference
  test-contains-all
  test-set-filter
  test-set-map
  test-set-reduce
  test-set-clear
  test-set-to-list

test-set-basics:
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
  expect-equals 0 sum

  {}.do --reversed: sum += it
  expect-equals 0 sum

  sum = 0
  {1, 2, 3}.do: sum += it
  expect-equals
    1 + 2 + 3
    sum

  sum = 0
  {1, 2, 3}.do --reversed: sum += it
  expect-equals
    1 + 2 + 3
    sum

  str := ""
  {1, 2, 3}.do: str += "$it "
  expect-equals
    "1 2 3 "
    str

  str = ""
  {1, 2, 3}.do --reversed: str += "$it "
  expect-equals
    "3 2 1 "
    str

  sum = 0
  {1, 2, 2}.do: sum += it
  expect-equals (1 + 2) sum

  sum = 0
  {1, 2, 2}.do --reversed: sum += it
  expect-equals (1 + 2) sum

test-set-equals:
  expect-equals {} {}
  expect-equals {1, 2} {1, 2}
  expect {1, 2} != {3, 4}

test-set-union:
  set := {1, 2}
  set.add-all set
  expect-equals {1, 2} set
  set.add-all {3, 4}
  expect-equals {1, 2, 3, 4} set

test-set-intersection:
  expect-equals {1, 2} ({1, 2}.intersect {1, 2})
  expect-equals {} ({1, 2}.intersect {3, 4})
  expect-equals {2} ({1, 2}.intersect {2, 3})


  set := {1, 2}
  other := {1, 2}
  set.intersect --in-place other
  expect-equals {1, 2} set

  set = {1, 2}
  other = {3, 4}
  set.intersect --in-place other
  expect-equals {} set

  set = {1, 2}
  other = {2, 3}
  set.intersect --in-place other
  expect-equals {2} set

test-set-difference:
  set := {1, 2}
  set.remove-all {1, 2}
  expect-equals {} set

  set = {1, 2}
  set.remove-all {2}
  expect-equals {1} set

  set = {1, 2}
  set.remove-all {3, 4}
  expect-equals {1, 2} set

test-contains-all:
  expect ({}.contains-all {})
  expect ({1, 2}.contains-all {1, 2})
  expect ({1, 2}.contains-all {2})
  expect ({1, 2}.contains-all {})
  expect (not {1, 2}.contains-all {2, 3})
  expect (not {1, 2}.contains-all {3, 4})

test-set-filter:
  expect-equals
    {1, 2}
    {1, 2}.filter: true
  expect-equals
    {}
    {1, 2}.filter: false
  expect-equals
    {1}
    {1, 2}.filter: 1 == it

  set := {1, 2}
  set.filter --in-place: true
  expect-equals {1, 2} set

  set.filter --in-place: false
  expect-equals {} set

  set = {1, 2}
  set.filter --in-place: 1 == it
  expect-equals {1} set

  set = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
  set.filter --in-place: it > 5
  expect-equals {6, 7, 8, 9, 10, 11, 12} set
  set.filter --in-place: it > 11
  expect-equals {12} set

test-set-map:
  expect-equals ({1, 2}.map: 2 * it) {2, 4}

test-set-reduce:
  expect-equals
    10
    {1, 2, 3, 4}.reduce: | sum e | sum + e

  expect-equals
    0
    {}.reduce --initial=0: 12
  expect-equals
    11
    {1, 2, 3, 4}.reduce --initial=1: | sum e | sum + e

test-set-clear:
  set := { 1, 2, 3 }
  set.clear
  expect set.is-empty

  set.clear
  expect set.is-empty

  for i := 0; i < 100; i++:
    set.add i
  for i := 0; i < 100; i++:
    expect (set.contains i)
  set.clear
  expect set.is-empty
  for i := 0; i < 100; i++:
    set.add i
  for i := 0; i < 100; i++:
    expect (set.contains i)
  set.clear
  expect set.is-empty

test-set-to-list:
  set := {}
  expect-equals [] set.to-list

  set = {1}
  expect-equals [1] set.to-list

  set = {1, 2}
  expect-equals [1, 2] set.to-list

  set = {}
  set.add 499
  set.add 99
  expect-equals [499, 99] set.to-list

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

test-remove:
  set := {}
  100.repeat: set.add it
  // Not enough to cause the set to be shrunk, but enough to generate skip
  // entries in the backing.
  20.repeat: set.remove it
  expect-equals 20 set.first
  // Leave 20 in there and remove enough after it to generate skip entries.
  20.repeat: set.remove it + 21
  expect-equals 20 set.first
  expect-equals 41 (second set)
  set.remove 20
  expect-equals 41 set.first
  expect-equals 42 (second set)
  set.do: it
  expect-equals 41 set.first
  expect-equals 42 (second set)
  set.do: it
  10.repeat:
    expect-equals 59 set.size
    expect-equals 99 set.last
    expect-equals 98 (penultimate set)
    if it % 2 == 0:
      20.repeat: set.remove 99 - it
    else:
      20.repeat: set.remove 80 + it
    expect-equals 79 set.last
    20.repeat: set.add 80 + it
    expect-equals 99 set.last
    expect-equals 98 (penultimate set)
  expect-equals 41 set.first
  expect-equals 42 (second set)

  map := {:}
  100.repeat: map[it] = it
  // Not enough to cause the map to be shrunk, but enough to generate skip
  // entries in the backing.
  20.repeat: map.remove it
  expect-equals 20 map.first
  // Leave 20 in there and remove enough after it to generate skip entries.
  20.repeat: map.remove it + 21
  expect-equals 20 map.first
  expect-equals 41 (second map)
  map.remove 20
  expect-equals 41 map.first
  expect-equals 42 (second map)
  map.do: it
  expect-equals 41 map.first
  expect-equals 42 (second map)
  map.do: it
  10.repeat:
    expect-equals 59 map.size
    expect-equals 99 map.last
    expect-equals 98 (penultimate map)
    if it % 2 == 0:
      20.repeat: map.remove 99 - it
    else:
      20.repeat: map.remove 80 + it
    expect-equals 79 map.last
    20.repeat: map[80 + it] = 80 + it
    expect-equals 99 map.last
    expect-equals 98 (penultimate map)
  expect-equals 41 map.first
  expect-equals 42 (second map)

// In terms of equality we only look at the string, but there is an
// extra field that enables us to distinguish instances from each other.
class Foo:
  hash-code_ := null
  unique := null
  string_ := null

  constructor .string_ .unique:

  hash-code -> int:
    return string_.hash-code

  operator == other -> bool:
    if other is not Foo: return false
    return other.string_ == string_

test-compatible-object:
  set := Set

  hello := Foo "Hello" 103
  set.add hello
  expect-equals 1 (set.size)

  world := Foo "World" 1
  // Do some tests before adding the new object to test the if_absent paths.
  expect-equals
    false
    set.contains world
  expect-equals
    null
    set.get world
  expect-equals
    "fish"
    set.get world --if-absent=:
      "fish"

  // Add the new object and verify it is there.
  set.add world
  expect-equals 2 (set.size)

  hello-2 := Foo "Hello" 42
  // This hello_2 is equal to the hello object, so this returns true.
  expect
    set.contains hello-2

  // This gets the hello object out of the set that matches the hello_2 object.
  hello-retrieved := set.get hello-2
  expect-equals 103 hello-retrieved.unique

  // Overwrite the hello object with the hello_2 object.
  set.add hello-2
  expect-equals 2 (set.size)

  // Check we get the right one back, using 'get'.
  hello-retrieved = set.get hello-2
  expect-equals 42 hello-retrieved.unique

  // Check we get the right one back, using 'get'.
  hello-retrieved = set.get hello
  expect-equals 42 hello-retrieved.unique

test-set-find set:
  baseline := set.size

  // Set does not contain "foo".
  ok := false
  result := set.get-by-hash_ 123
    --initial=:
      ok = true
      null  // Don't add anything to the set.
    --compare=: | x |
      expect x != "foo"
      false
  expect ok
  expect-equals null result

  // Add foo to the set using the hash code.
  h := "foo".hash-code
  ok = false
  result = set.get-by-hash_ h
    --initial=:
      ok = true
      "foo"      // Add foo to the set.
    --compare=: | x |
      expect x != "foo"  // It's not already there.
      false              // So the compare is always false.
  expect
    set.contains "foo"
  expect-equals "foo" result
  expect-equals baseline + 1 set.size

  // Check that "foo" is now present and findable using its hash code.
  ok = false
  result = set.get-by-hash_ h
    --initial=:
      throw "unreachable"
    --compare=: | x |
      if x == "foo":
        ok = true
      x == "foo"
  expect ok
  expect-equals "foo" result

  // Add "bar" in the conventional way.
  set.add "bar"
  expect-equals baseline + 2 set.size

  // We have an object that is not a string, that can be used to probe
  // whether a string is in the set.
  bar-probe := Stringlike 'b' 'a' 'r'
  ok = false
  result = set.get-by-hash_ bar-probe.hsh-cd
    --initial=:
      throw "unreachable"
    --compare=: | x |
      equality := bar-probe.matches x
      if equality:
        ok = true
      equality
  expect-equals baseline + 2 set.size
  expect-equals "bar" result
  expect ok

class Stringlike:
  letter1/int ::= ?
  letter2/int ::= ?
  letter3/int ::= ?
  hsh-cd/int ::= ?

  constructor .letter1 .letter2 .letter3:
    hsh-cd = #[letter1, letter2, letter3].to-string.hash-code

  matches x/string -> bool:
    if x.size != 3: return false
    if x[0] != letter1: return false
    if x[1] != letter2: return false
    if x[2] != letter3: return false
    return true

main:
  stats := process-stats
  initial-gcs := stats[system.STATS-INDEX-FULL-GC-COUNT]
  initial-compacts := stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]

  test-map
  test-set
  test-remove
  test-compatible-object
  test-set-find {}
  test-set-find {"one", "two", "three", "four", "five"}
  // 2650 has the same hash code as foo.
  test-set-find {"one", "two", "three", "four", "five", "2650"}

  stats = process-stats
  final-gcs := stats[system.STATS-INDEX-FULL-GC-COUNT]
  gcs := final-gcs - initial-gcs
  final-compacts := stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT]
  print "Performed $(gcs) full GC$(gcs == 1 ? "" : "s"), $(final-compacts - initial-compacts) of them compacting"
  expect 0 <= initial-gcs <= final-gcs
