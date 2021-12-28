// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x:

class A:
  field := x := 499
  instance:
    foo x   // The x of the field initializer must not be visible here.

main:
  (A).instance
