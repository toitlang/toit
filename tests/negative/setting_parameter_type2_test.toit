// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  foo / string := ""

  bar .foo/any:

main:
  (A).bar 499
