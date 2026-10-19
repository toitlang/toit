// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Untyped block parameters take their types from the expected block type.

class Box<T>:
  value/T
  constructor .value:
  with-value [block T -> none] -> none: block.call value
  maybe --if-absent/Lambda?=null [--if-present T -> none] -> none:

take-int [block int -> none] -> none: block.call 1
take-two [block int string -> none] -> none: block.call 1 "x"

main:
  list/List<int> := [1, 2]
  list.do: it.foo                         // Error.
  list.do: | x | x.foo                    // Error.
  list.do: | x/any | x.foo                // OK: explicitly 'any'.
  list.do: | x/num | x.foo                // Error on 'num'.
  list.map: it.size                       // Error.
  list.do: | x | x = "str"                // Error: 'x' is an 'int'.

  map/Map<string, int> := {:}
  map.do: | k v | k.foo v.foo             // Error on both.
  map.do --keys: it.foo                   // Error.

  // Statics and constructors.
  take-int: it.foo                        // Error.
  take-two: | a | a.foo                   // Error: fewer parameters is fine.
  take-two: | a b | b.foo                 // Error on 'b'.
  List 3: it.foo                          // Error.

  // Generic receivers and named blocks.
  box/Box<string> := Box "x"
  box.with-value: it.foo                  // Error.
  box.maybe --if-present=: it.foo         // Error.

  // Raw receivers have nothing to infer.
  raw/Box := box
  raw.with-value: it.foo                  // OK.

  // Named blocks may be passed to several calls: no inference.
  named := : | x | x.foo                  // OK.
  list.do named
  map.do --keys named

  // Nested blocks.
  nested/List<List<string>> := []
  nested.do: it.do: it.foo                // Error.

  // Inferred parameters flow into other checks.
  s/string := ""
  list.do: s = it                         // Error.
  unresolved
