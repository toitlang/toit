// Copyright (C) 2021 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:

class B:
  constructor:
    return A

  constructor.named:

main:
  b := B
