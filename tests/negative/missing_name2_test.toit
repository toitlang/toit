// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo -- --foo:
  unresolved

bar --foo --:
  unresolved

foo [--] [--foo]:
  unresolved

bar [--foo] [--]:
  unresolved

gee --

gee -- -> none:

gee ---> none:
