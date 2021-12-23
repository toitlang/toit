// Copyright (C) 2018 Toitware ApS. All rights reserved.

class A:
  foo := 1
  foo:
    return "clash"
  foo= x:
    "clash too"

main:
  print (A).foo
