// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

class A:
  field / string
  constructor .field:

main:
  (A "str").field = "can't assign to final"
