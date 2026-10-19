// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Element types of fresh collections in untyped locals are inferred from
// everything the method puts into them.

class Box<T>:
  value/T
  constructor .value:

main:
  a := [1, 2]
  a.add 3
  a.first.foo                  // Error: int.

  b := [1]
  b.add "x"
  b.first.foo                  // OK: any.

  c := []
  c.add "s"
  c.first.foo                  // Error: string.

  d := []
  d.first.foo                  // OK: raw.

  e := {"k": 1}
  e["j"] = 2
  e.do: | k v | k.foo          // Error: string.

  f := {1, 2}
  f.add 2.5
  f.first.foo                  // Error: num.

  g := Box 3
  g.value.foo                  // Error: int.

  h := [1, 2, 3, 4, 5]
  h.add 6
  h.first.foo                  // Error: int.

  i := [1, 2, 3, 4, 5]
  i.add "x"
  i.first.foo                  // OK: any.

  j := []
  j.add-all [1, 2]
  j.first.foo                  // Error: int.

  k := []
  raw/List := ["x"]
  k.add-all raw
  k.first.foo                  // OK: unknown.

  l := [1]
  l2 := l
  l2.add "x"
  l.first.foo                  // OK: alias widened.

  m := [null, 1]
  m.first.foo                  // Error: int?.

  n := [1]
  n = ["x"]
  n.first.foo                  // OK: reassignment widened.

  // Expressions get precise types too.
  takes-strings [1]            // Error.
  takes-strings ["x"]          // OK.
  takes-strings []             // OK.

  unresolved

takes-strings list/List<string>:
