// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo -> none:
  return 499

bar:
  foo.call_on_none

gee:
  bar.call_on_none

main:
  bar
  unresolved
