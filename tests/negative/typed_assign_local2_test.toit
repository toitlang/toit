// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

foo param/int:
  param = "str"

main:
  foo 499
