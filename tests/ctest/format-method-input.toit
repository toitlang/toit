// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

flat first second -> int:
  return 0

source-split
    first
    -> int
    second
:
  return 0

plain first second:
  null

shapes value/string? --named=1 [block] -> int?:
  return 0

class Holder:
  static declaration value -> int:
    return value

  operator [] index -> int:
    return index

class Fields:
  value/any
  other/any

  constructor this.value .other:
    null

operator-name -> int:
  return 0

attached value/List/*<int>*/ --marker="->" -> /* Describes result. */ bool:
  return false

colon-comment value -> int: /* Describes body. */
  return value

frozen  first  second  // Keep   every byte.
    -> int
:
  return 0

main:
  null
