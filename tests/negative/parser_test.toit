// Copyright (C) 2019 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:
  field1/string

main:
  a := A
  // The field type is wrong, but we already reported an error
  // during compilation.
  throw "fail here"
