// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo x/int x/string y/string y/int:
  x.copy 1
  y.copy 2
  unresolved
bar --name [--name]:
gee --name --name:

main:
  foo 1 "str" "str" 3
  bar --name=(: it) --name
  gee --name --name
