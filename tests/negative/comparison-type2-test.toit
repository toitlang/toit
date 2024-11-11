// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo -> any:
  return "foo"

class A:
  operator == other -> any:
    return foo

main:
  a := A
  print (a == "foo")
