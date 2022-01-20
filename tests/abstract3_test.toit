// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  gee: return 499
  abstract foo x y=gee --named1=1 --named2=2
  abstract bar y=gee [x] [--block] --named1=1 --named2=2

class B extends A:
  foo x:
  foo x --named1:
  foo x --named2:
  foo x --named1 --named2:
  foo x y:
  foo x y --named1:
  foo x y --named2:
  foo x y --named1 --named2:

  bar [x] [--block]:
  bar [x] [--block] --named1:
  bar [x] [--block] --named2:
  bar [x] [--block] --named1 --named2:
  bar y [x] [--block]:
  bar y [x] [--block] --named1:
  bar y [x] [--block] --named2:
  bar y [x] [--block] --named1 --named2:

class C extends A:
  foo x y --named1 --named2=2:
  foo x y --named2=2:
  foo x --named1 --named2=2:
  foo x --named2=2:

  bar [x] [--block] --named1=1 --named2:
  bar y [x] [--block] --named1=1 --named2:
  bar [x] [--block] --named1=1:
  bar y [x] [--block] --named1=1:

abstract class D:
  abstract method --arg1 --arg2=0
  abstract method --arg2 --arg3=0
  abstract method --arg3 --arg1=0

class E extends D:
  method --arg1=0 --arg2=0 --arg3=0:

abstract class F:
  abstract method --arg1=0 --arg2=0 --arg3=0

class G extends F:
  method --arg1 --arg2=0:
  method --arg2 --arg3=0:
  method --arg3 --arg1=0:
  method:
  method --arg1 --arg2 --arg3:

main:
  // Just tests that there isn't any error or warning with the classes.
  b := B
  c := C
  d := E
  g := G
