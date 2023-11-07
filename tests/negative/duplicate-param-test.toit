// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
