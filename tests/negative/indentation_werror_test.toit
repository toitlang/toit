// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: -Werror

foo
  x:
  print x

main:
  foo 499
  exit 1
