// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:
  operator + x/int -> int:
    return x

main:
  a /A := A
  a++
