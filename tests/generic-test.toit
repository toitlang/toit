// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Type arguments are checked statically and erased at runtime.

class Box<T>:
  value/T? := null

  constructor:
  constructor .value:

  get -> T: return value
  set v/T -> none: value = v

class Pair<A, B>:
  first/A
  second/B
  constructor .first .second:

  swap -> Pair<B, A>: return Pair second first

class IntBox extends Box<int>:
  double -> int: return value * 2

interface Container<E>:
  element -> E

class Holder<E> implements Container<E>:
  element/E
  constructor .element:

sum l/List<int> -> int:
  result := 0
  l.do: result += it
  return result

first-key m/Map<string, int> -> string:
  return m.keys.first

main:
  box/Box<string> := Box "hello"
  s/string := box.get
  expect-equals "hello" s
  box.set "world"
  expect-equals "world" box.value

  // Raw types are compatible with parameterized ones in both directions.
  raw/Box := box
  typed/Box<string> := raw
  expect-identical box typed

  pair/Pair<int, string> := Pair 1 "one"
  i/int := pair.first
  swapped/Pair<string, int> := pair.swap
  expect-equals "one" swapped.first
  expect-equals 1 swapped.second

  // Subclass with concrete type arguments.
  int-box := IntBox
  int-box.set 21
  n/int := int-box.get
  expect-equals 42 int-box.double
  as-box/Box<int> := int-box
  expect-equals 21 as-box.get

  // Interfaces with type arguments.
  container/Container<float> := Holder 1.5
  f/float := container.element
  expect-equals 1.5 f

  // Core collections.
  l/List<int> := []
  l.add 1
  l.add 2
  x/int := l[0]
  expect-equals 1 x
  expect-equals 2 l.last
  expect-equals 3 (sum l)
  expect-equals 3 (sum [1, 2])
  copy/List<int> := l.copy
  expect-list-equals l copy
  d/Deque<int> := Deque
  d.add 3
  as-list/List<int> := d
  expect-equals 3 as-list.first

  m/Map<string, int> := {:}
  m["a"] = 1
  v/int := m["a"]
  expect-equals 1 v
  maybe/int? := m.get "b"
  expect-null maybe
  expect-equals "a" (first-key m)
  nested/Map<string, List<int>> := {:}
  nested["l"] = l
  y/int := nested["l"][1]
  expect-equals 2 y

  st/Set<string> := {}
  st.add "x"
  expect (st.contains "x")
  e/string := st.first
  expect-equals "x" e

  // `as` with type arguments only checks the class at runtime.
  any-list/any := ["not", "ints"]
  ints := any-list as List<int>
  expect-equals 2 ints.size
  expect-throw "AS_CHECK_FAILED": any-list as Map<string, int>

  // Covariance: List<int> is a List<int?> and a List<any>.
  nullable/List<int?> := l
  anys/List<any> := l
  expect-equals 2 nullable.size
  expect-equals 2 anys.size
