// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Predicates are declared `-> truthy`: truthiness is part of the language, so
// non-bool results are fine. Results that are always true are warned about.
monitor Latch:
  value_ := null
  wait-good: await: value_ != null         // OK.
  wait-truthy: await: value_               // OK: truthiness.
  wait-bad: await: |a| true                // Error: no arguments.

main:
  list := [1, 2, 3]
  x/any := 1

  // Collection predicates.
  list.every: it == 1            // OK.
  list.any: x or false           // OK: `or` yields any.
  list.filter: it & 1            // Warning: an int is always truthy.
  list.every: 42                 // Warning: always true.
  list.filter: |a b| true        // Error: too many parameters.
  list.do: |a b| null            // Error: too many parameters.

  // Sets and maps.
  set := {1, 2}
  set.every: it == 1             // OK.
  map := {1: 2}
  map.every: |k v| k == v        // OK.
  map.any --keys: |k v| true     // Error: --keys passes only the key.
  map.do: |k v extra| null       // Error: too many parameters.

  // ByteArrays.
  bytes := #[1, 2]
  bytes.every: it == 1           // OK.
  bytes.every: |b/string| true   // Error: elements are ints.

  // List.equals.
  list.equals [1] --element-equals=: |a b| a == b   // OK.
  list.equals [1] --element-equals=: |a| true       // OK: fewer parameters.
  list.equals [1] --element-equals=: |a b c| true   // Error: too many parameters.

  // assert and catch.
  assert: x == 1                 // OK.
  assert: x                      // OK: truthiness.
  catch --trace=(: |e s| true): null       // OK.
  catch --unwind=(: |e s/string| true): null  // Error: the stack is a ByteArray?.

  // Error blocks that only have a side effect yield null.
  int.parse "x" --if-error=: print "bad int"     // OK.
  map.get 3 --if-absent=: print "absent"         // OK.
  // Compare blocks may return any num.
  list.sort: |a b| (a - b).to-float               // OK.

  // Other typed core blocks: parameter types and arity.
  5.repeat: |i/int| null         // OK.
  5.repeat: |i/string| null      // Error: index is an int.
  5.repeat: |a b| null           // Error: too many parameters.
  "abc".do: |c/int?| null        // OK.
  "abc".do: |c/int| null         // OK statically; `int?` into `int` is only checked at runtime.
  "abc".do --runes: |c/int| null // OK.
  list.sort: |a/int b/int| a < b // Error: compare must return a num.
  list.sort: |a b| a - b         // OK: any.
