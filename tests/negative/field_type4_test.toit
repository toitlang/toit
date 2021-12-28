// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:
  x / string := null

confuse x: return x

main:
  a := A
