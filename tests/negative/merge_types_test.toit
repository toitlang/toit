// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

confuse x -> any: return x
main:
  x := (confuse true) ? 1 : 0
  x.foo
