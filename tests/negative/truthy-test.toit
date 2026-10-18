// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Any value can be stored in a 'truthy' slot. A 'truthy' value can only be
// used as a condition.

class A:

pick list/List [predicate any -> truthy] -> List:
  result := []
  list.do: if predicate.call it: result.add it  // OK.
  return result

leak list/List [predicate any -> truthy] -> bool:
  return predicate.call list.first  // Error.

leak-any list/List [predicate any -> truthy]:
  return predicate.call list.first  // Error: unannotated methods return 'any'.

forward list/List [predicate any -> truthy] -> List:
  return pick list predicate  // OK.

identity x/truthy -> truthy:
  return x  // OK.

not-truthy x/truthy -> bool:
  return not x  // OK.

maybe-falls-through x -> truthy:
  if x: return true  // OK, and so is the implicit 'return null'.

class Holder:
  field/truthy := null

class Box<T>:
class TruthyBox extends Box<truthy>:  // Error.

main:
  list := [1, 2]
  a := A
  n/int? := null

  // Producers.
  pick list: it == 1              // OK.
  pick list: it                   // OK: 'any'.
  pick list: n                    // OK: nullable.
  pick list: null                 // Warning: always false.
  pick list: 42                   // Warning.
  pick list: a                    // Warning.
  pick list: print it             // Warning: yields null.
  pick list:
    print it
    it > 1                        // OK.
  pick list: |x/int| "str"        // Warning.
  identity 3                      // Warning.
  identity n                      // OK.
  identity (print 3)              // Error.
  t/truthy := a                   // Warning.

  // Consumers.
  x := identity n
  if x: print "yes"               // OK.
  while x: break                  // OK.
  y := x ? 1 : 2                  // OK.
  z := x and true                 // OK.
  w := x or false                 // OK.
  if not z: print "no"            // OK.
  if w: print "w"                 // OK.
  u/truthy := z                   // OK.
  v := identity x                 // OK.
  if (x is A): print "A"          // OK.
  print x                         // Error.
  print (x as any)                // OK: explicit escape.
  x.foo                           // Error.
  x == null                       // Error.
  s/any := x                      // Error.
  b/bool := x                     // Error.
  list.add x                      // Error.
  "$x"                            // Error.
  list.map: identity it           // Error.
  (Holder).field = x              // OK.
  TruthyBox
  m := y > 0 ? x : 3              // Merging keeps 'truthy'.
  print m                         // Error.
  unresolved
