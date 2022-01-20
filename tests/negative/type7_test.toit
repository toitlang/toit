// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  x / string? := null
  y / any := null
  z := null

  constructor.x .x:
  constructor.x2 .x/any:
  constructor.x3 .x/A:

  constructor.y .y:
  constructor.y2 .y/string:
  constructor.y3 .y/any:

  constructor.z .z:
  constructor.z2 .z/string:

  constructor.x --named/bool .x:
  constructor.x2 --named/bool .x/any:
  constructor.x3 --named/bool .x/A:

  constructor.y --named/bool .y:
  constructor.y2 --named/bool .y/string:
  constructor.y3 --named/bool .y/any:

  constructor.z --named/bool .z:
  constructor.z2 --named/bool .z/string:

  foo .x:
  foo2 .x/any:
  foo3 .x/A:

  bar .y:
  bar2 .y/string:
  bar3 .y/any:

  gee .z:
  gee2 .z/string:

  foo --named/bool .x:
  foo2 --named/bool .x/any:
  foo3 --named/bool .x/A:

  bar --named/bool .y:
  bar2 --named/bool .y/string:
  bar3 --named/bool .y/any:

  gee --named/bool .z:
  gee2 --named/bool .z/string:

main:
  a := A.x "foo"
  a = A.x2 499
  a = A.y 499
  a = A.y2 "foo"
  a = A.y3 true
  a = A.z 499
  a = A.z2 "foo"

  a = A.x 499
  a = A.y2 499
  a = A.z2 499

  a = A.x --named "foo"
  a = A.x2 --named 499
  a = A.y --named 499
  a = A.y2 --named "foo"
  a = A.y3 --named true
  a = A.z --named 499
  a = A.z2 --named "foo"

  a = A.x --named 499
  a = A.y2 --named 499
  a = A.z2 --named 499

  a.foo "foo"
  a.foo2 499
  a.bar 499
  a.bar2 "foo"
  a.bar3 true
  a.gee 499
  a.gee2 "foo"

  a.foo 499
  a.bar2 499
  a.gee2 499

  a.foo --named "foo"
  a.foo2 --named 499
  a.bar --named 499
  a.bar2 --named "foo"
  a.bar3 --named true
  a.gee --named 499
  a.gee2 --named "foo"

  a.foo --named 499
  a.bar2 --named 499
  a.gee2 --named 499

  unresolved
