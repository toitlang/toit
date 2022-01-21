// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [x] --named=x:
  unresolved

foo2 [x] [--named]=x:
  unresolved

foo2b [x] [--named=x]:
  unresolved

foo3 [x=(:499)]:
  unresolved

foo3b [x]=(:499):
  unresolved

foo4 [x] [y]=x:
  unresolved

main:
  foo: 499
  foo2 --named=(: 499): 42
  foo2b --named=(: 499): 42
  foo3: 499
  foo3b: 499
  foo4 (: 42): 42
