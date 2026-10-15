// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Box<T>:
  value/T? := null
  constructor:
  constructor .value:
  get -> T: return value
  set v/T -> none: value = v
  set-bad -> none: value = 42

class Pair<A, B>:
  first/A
  second/B
  constructor .first .second:

class IntBox extends Box<int>:
  bad -> string: return value

class Tag:

take-ints l/List<int> -> none:
make-strings -> List<string>: return []

main:
  box/Box<string> := Box
  i/int := box.get
  box.set 42
  box.set "ok"
  tag-box/Box<Tag> := box
  int-box := IntBox
  str-box/Box<string> := int-box
  ok-box/Box<int> := int-box
  pair/Pair<int, string> := Pair 1 "one"
  s/string := pair.first
  n/int := pair.second

  l/List<string> := []
  l.add "a"
  l.add 1
  l[0] = 2
  x/int := l[0]
  l2/List<int> := l + ["b"]
  l3/List<Tag> := l.copy
  take-ints l
  take-ints []
  take-ints (List 3 0)
  take-ints make-strings

  m/Map<string, int> := {:}
  m[1] = 1
  m["b"] = "c"
  v/string := m["a"]
  vs/List<string> := m.values
  nested/Map<string, List<int>> := {:}
  nested["l"] = l
  nested["l"] = [1]
  bad-nested/Map<string, List<string>> := nested

  st/Set<int> := {}
  st.add "s"
  st.contains "s"
  d/Deque<int> := Deque
  d.add "s"
  dl/List<string> := d

  // Raw types and `any` arguments are compatible in both directions.
  raw/List := l
  raw.add 1
  typed/List<string> := raw
  anys/List<any> := l
  back/List<string> := anys

  unresolved
