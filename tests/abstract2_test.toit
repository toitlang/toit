// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract foo x
  abstract foo x --named1
  abstract foo x --named2
  abstract foo x --named1 --named2
  abstract foo x y
  abstract foo x y --named1
  abstract foo x y --named2
  abstract foo x y --named1 --named2

  abstract bar [x] [--block]
  abstract bar [x] [--block] --named1
  abstract bar [x] [--block] --named2
  abstract bar [x] [--block] --named1 --named2
  abstract bar y [x] [--block]
  abstract bar y [x] [--block] --named1
  abstract bar y [x] [--block] --named2
  abstract bar y [x] [--block] --named1 --named2

class B extends A:
  foo x y=499 --named1=1 --named2=2:
  bar y=42 [x] [--block] --named1=1 --named2=2:

class C extends A:
  foo x y --named1 --named2=2:
  foo x y --named2=2:
  foo x --named1 --named2=2:
  foo x --named2=2:

  bar [x] [--block] --named1=1 --named2:
  bar y [x] [--block] --named1=1 --named2:
  bar [x] [--block] --named1=1:
  bar y [x] [--block] --named1=1:

main:
  // Just tests that there isn't any error or warning with the classes.
  b := B
  c := C
