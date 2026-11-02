// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Calls that the generated code can't resolve take a slow path through the
// dispatch table. The rows of the table overlap, so a slot can belong to
// another class, and then the lookup has to fail.

interface Shape:
  area -> int

interface Named:
  name -> string

class Square implements Shape Named:
  side/int
  constructor .side:
  area -> int: return side * side
  name -> string: return "square"

class Circle implements Shape:
  r/int
  constructor .r:
  area -> int: return 3 * r * r

class Other:
  value -> int: return 42

class Numbers:
  operator + other -> string: return "plus $other"
  operator [] index -> string: return "at $index"
  operator []= index value: return "put $index $value"
  size -> string: return "my size"

confuse x -> any:
  return x

test-interfaces:
  objects := [Square 2, Circle 3, Other, 7, "text", null, 1.5]
  expect-equals [true, true, false, false, false, false, false] (objects.map: it is Shape)
  expect-equals [true, false, false, false, false, false, false] (objects.map: it is Named)
  expect-equals 4 (confuse (Square 2)).area
  expect-equals 27 (confuse (Circle 3)).area

test-byte-array-interface:
  // ByteArray is an interface, so this is an interface check too.
  expect (confuse #[1, 2]) is ByteArray
  expect (confuse "text") is not ByteArray
  expect (confuse [1]) is List
  expect (confuse "text") is string

test-lookup-failures:
  // Each of these reaches the slow path for a receiver without the method.
  expect-throw "LOOKUP_FAILED": (confuse (Other)).area
  expect-throw "LOOKUP_FAILED": (confuse (Circle 1)).name
  expect-throw "LOOKUP_FAILED": (confuse 3).area
  expect-throw "LOOKUP_FAILED": (confuse null).area
  expect-throw "LOOKUP_FAILED": (confuse "text").value
  expect-throw "LOOKUP_FAILED": (confuse 1.5).name

test-operators:
  // The runtime dispatches these when the receiver isn't a number or a list.
  numbers := confuse Numbers
  expect-equals "plus 1" numbers + 1
  expect-equals "at 2" numbers[2]
  numbers[3] = 4
  expect-equals "my size" numbers.size
  expect-throw "LOOKUP_FAILED": (confuse (Other)) + 1
  expect-throw "LOOKUP_FAILED": (confuse null)[0]

main:
  test-interfaces
  test-byte-array-interface
  test-lookup-failures
  test-operators
