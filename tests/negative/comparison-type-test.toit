// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  operator == other -> string:
    return "str"

  operator <= other:

  operator < other:
    return "str"

  operator >= other -> bool?:
    return true

class B:
  operator == other -> any:
    return false

foo str/string:

main:
  b := B
  foo (b == "foo")
