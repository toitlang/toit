// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

class A:
  field1/string

main:
  a := A
  // The field type is wrong, but we already reported an error
  // during compilation.
  throw "fail here"
